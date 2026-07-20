import AVFoundation
import CoreImage
import CoreVideo
import Metal
import QuartzCore

/// 超广角采集 + 陀螺仪地平线稳定管线
final class CameraManager: NSObject, ObservableObject {

    // MARK: - Public

    @Published var isRunning = false

    /// MTKView 预览回调：主线程收到已处理的 CIImage
    var previewFrame: ((CIImage) -> Void)?

    /// 陀螺仪快照提供者（由 MotionManager 注入）
    var motionSnapshot: () -> (roll: Double, offsetX: Double, offsetY: Double) = { (0, 0, 0) }

    // MARK: - Session

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "maimai.camera.session")
    private let dataQueue = DispatchQueue(label: "maimai.camera.data", qos: .userInteractive)
    private var configured = false

    private let videoOutput = AVCaptureVideoDataOutput()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Smoothing state (dataQueue only)

    private var smoothRoll: Double = 0.0
    private var smoothOffX: Double = 0.0
    private var smoothOffY: Double = 0.0

    private let rollAlpha: Double = 0.25        // roll 平滑
    private let transAlpha: Double = 0.10       // 平移平滑

    // MARK: - Crop constants

    /// 裁剪比例：取短边的 54%，3:4 宽高比
    private let cropScale: Double = 3.0 / 5.0 * 0.90
    private let cropRatio: Double = 3.0 / 4.0   // 宽:高

    // MARK: - Lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                if ok { self?.startSession() }
            }
        default:
            break
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
        DispatchQueue.main.async { self.isRunning = false }
    }

    private func startSession() {
        sessionQueue.async { [weak self] in
            guard let self, !self.configured else {
                if !(self?.session.isRunning ?? false) { self?.session.startRunning() }
                return
            }
            self.configure()
            self.session.startRunning()
            DispatchQueue.main.async { self.isRunning = true }
        }
    }

    // MARK: - Configure

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        defer { session.commitConfiguration(); configured = true }

        // 优先超广角 → 回退广角
        guard let device = ultraWide() ?? wide(),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        // 4:3 + 最高帧率
        enforce4by3(device)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        guard session.canAddOutput(videoOutput) else { return }
        session.addOutput(videoOutput)

        // 硬件防抖
        if let conn = videoOutput.connection(with: .video), conn.isVideoStabilizationSupported {
            conn.preferredVideoStabilizationMode = .cinematicExtended
        }
    }

    private func ultraWide() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
    }

    private func wide() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    private func enforce4by3(_ device: AVCaptureDevice) {
        let target = 4.0 / 3.0
        var best: (AVCaptureDevice.Format, Int32, Float)? = nil

        for fmt in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            guard d.width > 0, abs(Double(d.width) / Double(d.height) - target) < 0.01 else { continue }
            let maxFPS = fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            guard maxFPS >= 30 else { continue }
            let fps: Float = maxFPS >= 60 ? 60 : 30
            if d.width > (best?.1 ?? 0) { best = (fmt, d.width, fps) }
        }

        guard let (fmt, _, fps) = best else { return }
        try? device.lockForConfiguration()
        device.activeFormat = fmt
        let dur = CMTime(value: 1, timescale: Int32(fps))
        device.activeVideoMinFrameDuration = dur
        device.activeVideoMaxFrameDuration = dur
        device.videoZoomFactor = 1.0
        device.unlockForConfiguration()
    }

    // MARK: - Frame processing

    private func processFrame(_ buf: CMSampleBuffer) {
        guard let pixelBuf = CMSampleBufferGetImageBuffer(buf) else { return }

        let ci = CIImage(cvPixelBuffer: pixelBuf).oriented(.right)
        let w = ci.extent.width
        let h = ci.extent.height

        let snap = motionSnapshot()

        // EMA 平滑
        smoothRoll  += rollAlpha  * (snap.roll    - smoothRoll)
        smoothOffX  += transAlpha * (snap.offsetX - smoothOffX)
        smoothOffY  += transAlpha * (snap.offsetY - smoothOffY)

        let angle = CGFloat(-smoothRoll)
        let cx = w / 2; let cy = h / 2

        // 绕中心反旋转
        let rotated = ci.transformed(by:
            CGAffineTransform(translationX: -cx, y: -cy)
                .concatenating(CGAffineTransform(rotationAngle: angle))
                .concatenating(CGAffineTransform(translationX: cx, y: cy))
        )

        let re = rotated.extent
        let shorter = min(w, h)
        let cropW = shorter * CGFloat(cropScale)
        let cropH = cropW * CGFloat(1.0 / cropRatio)  // 宽 / (3/4) = 4:3 高

        let marginX = max(0, (re.width  - cropW) / 2)
        let marginY = max(0, (re.height - cropH) / 2)

        // 旋转坐标系下的平移
        let cosA = cos(angle); let sinA = sin(angle)
        let rOffX = CGFloat(smoothOffX) * cosA - CGFloat(smoothOffY) * sinA
        let rOffY = CGFloat(smoothOffX) * sinA + CGFloat(smoothOffY) * cosA

        let shiftX = rOffX * marginX * 0.9
        let shiftY = rOffY * marginY * 0.9

        let cropRect = CGRect(
            x: re.midX - cropW / 2 + shiftX,
            y: re.midY - cropH / 2 + shiftY,
            width:  cropW,
            height: cropH
        )

        let result = rotated
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))

        // 发送到预览
        DispatchQueue.main.async { [weak self] in
            self?.previewFrame?(result)
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        processFrame(sampleBuffer)
    }
}
