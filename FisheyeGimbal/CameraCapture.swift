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
            case .ultraWide: return .builtInUltraWideAngleCamera
            }
        }
    }

    /// 每帧回调：(CVPixelBuffer, 时间戳秒)
    var onFrame: ((CVPixelBuffer, Double) -> Void)?

    @Published var running = false
    @Published var lastError: String?
    @Published var sourceSize: CGSize = .zero

    private let sessionQueue = DispatchQueue(label: "fe.camera.session")
    private let videoQueue = DispatchQueue(label: "fe.camera.video",
                                           qos: .userInitiated)
    private var output: AVCaptureVideoDataOutput?
    private var configured = false
    private var fps: Int = 30
    private(set) var backCamera: BackCamera = .wideAngle
    private var deviceInput: AVCaptureDeviceInput?

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

    func start(fps: Int = 30) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.fps = fps
            if !self.configured {
                self.configure(fps: fps)
                self.configured = true
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            DispatchQueue.main.async { self.running = self.session.isRunning }
        }
    }

    /// 切换夹持的镜头（1x / 0.5x）。会重建 input。
    func selectBackCamera(_ cam: BackCamera) {
        sessionQueue.async { [weak self] in
            guard let self, cam != self.backCamera else { return }
            self.backCamera = cam

            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [cam.deviceType],
                                                             mediaType: .video,
                                                             position: .back)
            guard let device = discovery.devices.first
                    ?? AVCaptureDevice.default(cam.deviceType, for: .video, position: .back) else {
                DispatchQueue.main.async { self.lastError = "找不到该镜头：\(cam.title)" }
                return
            }

            self.session.beginConfiguration()
            if let old = self.deviceInput {
                self.session.removeInput(old)
                self.deviceInput = nil
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.lastError = "切换镜头失败" }
                    return
                }
                self.session.addInput(input)
                self.deviceInput = input
                self.disableSystemCorrections(device)
                self.applyFPS(self.fps, to: device)
                if let dims = device.activeFormat.formatDescription.dimensions as CMVideoDimensions? {
                    let s = CGSize(width: Int(dims.width), height: Int(dims.height))
                    DispatchQueue.main.async { self.sourceSize = s }
                }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.lastError = "切换镜头失败: \(error.localizedDescription)" }
                return
            }
            self.session.commitConfiguration()
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
        // 有的设备把 0.5x 报成 .builtInUltraWideAngleCamera。
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [backCamera.deviceType, .builtInWideAngleCamera],
            mediaType: .video,
            position: .back)

        guard let device = discovery.devices.first
                ?? AVCaptureDevice.default(backCamera.deviceType, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            finishConfig(error: "找不到可用后置摄像头")
            return
        }

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
        out.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        out.alwaysDiscardsLateVideoFrames = true          // 宁可丢帧也不堆积延迟
        out.automaticallyConfiguresOutputBufferDimensions = false
        out.deliversPreviewSizedOutputBuffers = false
        out.setSampleBufferDelegate(self, queue: videoQueue)

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

        applyFPS(fps, to: device)

        session.commitConfiguration()

        // 报告源分辨率
        if let dims = device.activeFormat.formatDescription.dimensions as CMVideoDimensions? {
            let size = CGSize(width: Int(dims.width), height: Int(dims.height))
            DispatchQueue.main.async { self.sourceSize = size }
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

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        onFrame?(pb, ts.isFinite ? ts : CACurrentMediaTime())
    }
}
