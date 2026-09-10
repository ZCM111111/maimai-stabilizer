//
//  CameraCapture.swift
//  FisheyeGimbal
//
//  AVCaptureVideoDataOutput 取原始帧。
//
//  关键点：
//   * 关掉所有内置修正 —— videoStabilizationMode = .off，
//     geometricDistortionCorrectionEnabled = false。
//     我们要的是镜头的原始畸变像素，系统帮你掰直了反而没法标定。
//   * 用 AVCaptureSession.Preset.high，避免系统偷偷上 HDR / 多帧合成。
//   * 帧以 BGRA 直出，省掉 YUV->RGB 转换，直接进 Metal。
//

import AVFoundation
import CoreVideo
import CoreGraphics

final class CameraCapture: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    let session = AVCaptureSession()

    /// 外接鱼眼夹在哪个镜头上就选哪个。
    /// 夹在后置广角(1x)选 .wideAngle；夹在超广角(0.5x)选 .ultraWide。
    enum BackCamera: String, CaseIterable, Identifiable {
        case wideAngle
        case ultraWide

        var id: String { rawValue }

        var title: String {
            switch self {
            case .wideAngle: return "广角 1x"
            case .ultraWide: return "超广角 0.5x"
            }
        }

        var deviceType: AVCaptureDevice.DeviceType {
            switch self {
            case .wideAngle: return .builtInWideAngleCamera
            case .ultraWide: return .builtInUltraWideCamera
            }
        }
    }

    /// 每帧回调：(CVPixelBuffer, 时间戳秒)
    var onFrame: ((CVPixelBuffer, Double) -> Void)?

    @Published var running = false
    @Published var lastError: String?
    @Published var sourceSize: CGSize = .zero
    /// 实际协商到的像素格式（诊断用）
    @Published var negotiatedPixelFormat: OSType = 0
    /// 相机诊断信息（多行，直接显示在界面上）
    @Published var diagText: String = ""

    private var diagLines: [String] = []
    private var watchdog: DispatchWorkItem?
    private var didFallBack = false
    /// 已收到的帧数（看门狗用它判断"到底有没有出帧"）
    private(set) var frameCount: Int = 0
    private var observers: [NSObjectProtocol] = []

    /// 追加一行诊断（可从任意线程调用）
    func noteDiag(_ line: String) {
        print("[CAM] \(line)")
        RemoteLog.shared.log("CAM", line)
        DispatchQueue.main.async {
            self.diagLines.append(line)
            if self.diagLines.count > 14 { self.diagLines.removeFirst(self.diagLines.count - 14) }
            self.diagText = self.diagLines.joined(separator: "\n")
        }
    }

    private let sessionQueue = DispatchQueue(label: "fe.camera.session")
    private let videoQueue = DispatchQueue(label: "fe.camera.video",
                                           qos: .userInitiated)
    private(set) var output: AVCaptureVideoDataOutput?
    private var configured = false
    private var fps: Int = 30
    private var deviceInput: AVCaptureDeviceInput?

    /// 外接鱼眼夹在哪个镜头上。默认 0.5x 超广角。
    @Published private(set) var backCamera: BackCamera = .ultraWide

    // MARK: - 权限

    static func requestAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { completion(ok) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - 生命周期

    /// 装上会话状态观测。
    /// AVCaptureSession 启动失败/被中断是静默的 —— 没有这些 handler，什么都看不到。
    private func installObservers() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        let center = session

        func add(_ name: Notification.Name, _ tag: String) {
            let token = nc.addObserver(forName: name, object: center, queue: nil) { [weak self] note in
                guard let self else { return }
                // 必须写成 AVError(...)，因为 userInfo 里存的是 NSError
                var extra = ""
                if let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError {
                    extra = " err=\(err.code) \(err.localizedDescription)"
                }
                self.noteDiag(tag + extra)
            }
            observers.append(token)
        }

        add(.AVCaptureSessionRuntimeError, "会话运行错误")
        add(.AVCaptureSessionWasInterrupted, "会话被中断")
        add(.AVCaptureSessionInterruptionEnded, "会话中断结束")
        add(.AVCaptureSessionDidStartRunning, "会话已启动")
        add(.AVCaptureSessionDidStopRunning, "会话已停止")
    }

    func start(fps: Int = 30) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.fps = fps
            self.installObservers()

            let auth = AVCaptureDevice.authorizationStatus(for: .video)
            self.noteDiag("权限=\(Self.describe(auth))")
            guard auth == .authorized else {
                self.noteDiag("权限不足，相机不会启动")
                return
            }

            if !self.configured {
                self.configure(fps: fps)
                self.configured = true
            }
            self.noteDiag("输入数=\(self.session.inputs.count) 输出数=\(self.session.outputs.count)")

            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.noteDiag("startRunning 后 isRunning=\(self.session.isRunning)")
            DispatchQueue.main.async { self.running = self.session.isRunning }

            self.armWatchdog()
        }
    }

    /// 3.5 秒内没收到任何帧 -> 自动从 0.5x 退到 1x 重试一次
    private func armWatchdog() {
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let got = self.frameCount > 0
            self.noteDiag("看门狗: 收到帧数=\(self.frameCount)")
            guard !got, !self.didFallBack, self.backCamera == .ultraWide else { return }
            self.didFallBack = true
            self.noteDiag(">>> 超广角无帧，自动退到 1x 重试 <<<")
            DispatchQueue.main.async { self.lastError = "0.5x 无画面，已自动切到 1x" }
            self.selectBackCamera(.wideAngle)
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    static func describe(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized:    return "已授权"
        case .denied:        return "被拒绝"
        case .restricted:    return "受限"
        case .notDetermined: return "未决定"
        @unknown default:    return "未知"
        }
    }

    /// 切换夹持的镜头（1x / 0.5x）。重建 input + output。
    func selectBackCamera(_ cam: BackCamera) {
        sessionQueue.async { [weak self] in
            guard let self, cam != self.backCamera else { return }
            self.noteDiag(">>> 切换镜头 -> \(cam.title) <<<")
            self.backCamera = cam

            // 整段重建，不要手工拆装（顺序错了会静默失败）
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            for i in self.session.inputs { self.session.removeInput(i) }
            for o in self.session.outputs { self.session.removeOutput(o) }
            self.session.commitConfiguration()
            self.deviceInput = nil
            self.output = nil
            self.configured = false

            self.configure(fps: self.fps)
            self.configured = true
            if !self.session.isRunning { self.session.startRunning() }
            self.noteDiag("切换后 isRunning=\(self.session.isRunning) 输入=\(self.session.inputs.count) 输出=\(self.session.outputs.count)")
            DispatchQueue.main.async { self.running = self.session.isRunning }
            self.armWatchdog()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.running = false }
        }
    }

    func switchFPS(_ fps: Int) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice() else { return }
            self.applyFPS(fps, to: device)
            self.fps = fps
        }
    }

    // MARK: - 配置

    private func currentDevice() -> AVCaptureDevice? {
        if let input = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first {
            return input.device
        }
        return nil
    }

    /// 关掉系统内置的几何畸变校正 + 强制裁剪 + 数码变焦。
    /// 必须关：iPhone 会偷偷把广角畸变掰直，我们要的是镜头的原始像素，
    /// 否则标定无从谈起（而且 YUV 域已经有损了）。
    private func disableSystemCorrections(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            if device.isGeometricDistortionCorrectionSupported {
                device.isGeometricDistortionCorrectionEnabled = false
            }
            if device.videoZoomFactor != 1.0 {
                device.videoZoomFactor = 1.0
            }
            device.unlockForConfiguration()
        } catch {
            // 非致命：拿不到锁就跳过
        }
    }

    private func configure(fps: Int) {
        session.beginConfiguration()
        session.sessionPreset = .high

        // 选镜头：外接鱼眼夹在哪个镜头上就选哪个。
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [backCamera.deviceType, .builtInWideAngleCamera],
            mediaType: .video,
            position: .back)

        let first = discovery.devices.first(where: { $0.deviceType == backCamera.deviceType })
        guard let device = first
                ?? discovery.devices.first
                ?? AVCaptureDevice.default(backCamera.deviceType, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            finishConfig(error: "找不到可用后置摄像头")
            return
        }

        noteDiag("镜头=\(device.deviceType.rawValue.replacingOccurrences(of: "AVCaptureDeviceType", with: ""))")
        noteDiag("可用=\(device.isConnected ? "已连接" : "未连接")")
        noteDiag("发现设备数=\(discovery.devices.count)")

        // 关键顺序：先定 activeFormat，再加输出。
        // 之前是先 addOutput 再 applyFPS，session 可能锁在旧格式上。
        applyFPS(fps, to: device)

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                finishConfig(error: "无法添加摄像头输入")
                return
            }
            session.addInput(input)
            self.deviceInput = input
            disableSystemCorrections(device)
        } catch {
            finishConfig(error: "摄像头初始化失败: \(error.localizedDescription)")
            return
        }

        let out = AVCaptureVideoDataOutput()
        // 必须按这个输出实际支持的格式来挑。
        // 文档明确：videoSettings 里只能放 availableVideoPixelFormatTypes 的子集，
        // 否则系统会忽略整个字典并静默回退到 YUV。
        let available = out.availableVideoPixelFormatTypes
        let chosen = Self.pickPixelFormat(from: available)
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: chosen]
        out.alwaysDiscardsLateVideoFrames = true      // 宁可丢帧也不堆积延迟
        out.setSampleBufferDelegate(self, queue: videoQueue)

        noteDiag("候选格式=\(available.map { Self.fourCC($0) }.joined(separator: "/"))")
        noteDiag("选定格式=\(Self.fourCC(chosen))")
        DispatchQueue.main.async { self.negotiatedPixelFormat = chosen }

        guard session.canAddOutput(out) else {
            finishConfig(error: "无法添加视频输出")
            return
        }
        session.addOutput(out)
        self.output = out

        // 关掉 AVCaptureVideoDataOutput 层面的增稳
        if let conn = out.connection(with: .video), conn.isVideoStabilizationSupported {
            conn.preferredVideoStabilizationMode = .off
        }

        session.commitConfiguration()

        let fmt = device.activeFormat
        let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        noteDiag("activeFormat=\(dims.width)x\(dims.height)")
        noteDiag("帧率范围=\(fmt.videoSupportedFrameRateRanges.map { String(format: "%.0f-%.0f", $0.minFrameRate, $0.maxFrameRate) }.joined(separator: ","))")
        DispatchQueue.main.async {
            self.sourceSize = CGSize(width: Int(dims.width), height: Int(dims.height))
        }
    }

    private func applyFPS(_ target: Int, to device: AVCaptureDevice) {
        var best: AVCaptureDevice.Format?
        var bestScore = Int.max
        for f in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard dims.height >= 720 else { continue }
            let supports = f.videoSupportedFrameRateRanges.contains {
                Double(target) >= $0.minFrameRate - 0.5 && Double(target) <= $0.maxFrameRate + 0.5
            }
            guard supports else { continue }
            // 越接近 1920 宽越好
            let score = abs(Int(dims.width) - 1920)
            if score < bestScore {
                bestScore = score
                best = f
            }
        }
        guard let format = best else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let d = CMTime(value: 1, timescale: CMTimeScale(target))
            device.activeVideoMinFrameDuration = d
            device.activeVideoMaxFrameDuration = d
            device.unlockForConfiguration()
        } catch { /* 保持默认帧率 */ }
    }

    private func finishConfig(error: String) {
        session.commitConfiguration()
        DispatchQueue.main.async { self.lastError = error }
    }

    // MARK: - 像素格式选择

    /// 优先 BGRA（渲染管线直接吃），退而求其次 YUV。
    static func pickPixelFormat(from available: [OSType]) -> OSType {
        let prefer: [OSType] = [
            kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_32ARGB,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        for p in prefer where available.contains(p) { return p }
        return available.first ?? kCVPixelFormatType_32BGRA
    }

    /// OSType -> 可读四字符码
    static func fourCC(_ code: OSType) -> String {
        guard code != 0 else { return "----" }
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "?" })
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        frameCount &+= 1
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        onFrame?(pb, ts.isFinite ? ts : CACurrentMediaTime())
    }
}
