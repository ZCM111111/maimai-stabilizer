import AVFoundation
import CoreImage
import CoreVideo
import Photos
import UIKit
import VideoToolbox

// MARK: - Recording Quality

enum RecordingQuality: String, CaseIterable, Identifiable {
    case hd1080p60 = "1080p 60fps"
    case k4k60     = "4K 60fps"

    var id: String { rawValue }

    /// 输出分辨率（3:4 竖屏）
    var outputSize: (Int, Int) {
        switch self {
        case .hd1080p60: return (1080, 1440)
        case .k4k60:      return (2160, 2880)
        }
    }

    var bitRate: Int {
        switch self {
        case .hd1080p60: return 20_000_000
        case .k4k60:      return 50_000_000
        }
    }
}

// MARK: - Camera Manager

/// 超广角 60fps 采集 + 地平线稳定 + 录制
final class CameraManager: NSObject, ObservableObject {

    @Published var isRunning = false
    @Published var isRecording = false
    @Published var quality: RecordingQuality = .hd1080p60
    @Published var lastVideoURL: URL?

    var previewFrame: ((CIImage) -> Void)?
    var motionSnapshot: () -> (roll: Double, offsetX: Double, offsetY: Double) = { (0, 0, 0) }

    // MARK: - Session

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "maimai.camera.session")
    private let dataQueue = DispatchQueue(label: "maimai.camera.data", qos: .userInteractive)
    private var configured = false

    private let videoOutput = AVCaptureVideoDataOutput()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Smoothing state

    private var smoothRoll: Double = 0.0
    private var smoothOffX: Double = 0.0
    private var smoothOffY: Double = 0.0
    private let rollAlpha: Double = 0.25
    private let transAlpha: Double = 0.10

    // MARK: - Crop

    private let cropScale: Double = 3.0 / 5.0 * 0.90
    private let cropRatio: Double = 3.0 / 4.0

    // MARK: - Frame counter (dataQueue only)

    private var frameIndex: Int = 0

    // MARK: - Recording (dataQueue only)

    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingURL: URL?
    private var sessionAtSourceTime = false

    // MARK: - Lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                if ok { self?.startSession() }
            }
        default: break
        }
    }

    func stop() {
        dataQueue.async { [weak self] in self?.finishRecording() }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
        DispatchQueue.main.async { self.isRunning = false }
    }

    private func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.isRunning = true }
        }
    }

    // MARK: - Configure

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        defer { session.commitConfiguration(); configured = true }

        guard let device = ultraWide() ?? wide(),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        enforceBestFormat(device)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        guard session.canAddOutput(videoOutput) else { return }
        session.addOutput(videoOutput)

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

    /// 4:3 格式 + 最优帧率（优先60, 回退30）
    private func enforceBestFormat(_ device: AVCaptureDevice) {
        let target = 4.0 / 3.0
        var best60: (AVCaptureDevice.Format, Int32)? = nil
        var best30: (AVCaptureDevice.Format, Int32)? = nil

        for fmt in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            guard d.width > 0, d.height > 0,
                  abs(Double(d.width) / Double(d.height) - target) < 0.01 else { continue }
            let maxFPS = fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            guard maxFPS >= 30 else { continue }
            if maxFPS >= 60 {
                if d.width > (best60?.1 ?? 0) { best60 = (fmt, d.width) }
            } else {
                if d.width > (best30?.1 ?? 0) { best30 = (fmt, d.width) }
            }
        }

        guard let (fmt, _) = best60 ?? best30 else { return }
        let maxFPS = fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        let fps: Int32 = maxFPS >= 60 ? 60 : 30

        try? device.lockForConfiguration()
        device.activeFormat = fmt
        let dur = CMTime(value: 1, timescale: fps)
        device.activeVideoMinFrameDuration = dur
        device.activeVideoMaxFrameDuration = dur
        if #available(iOS 17.0, *) {
            device.videoZoomFactor = max(1.0, device.minAvailableVideoZoomFactor)
        } else {
            device.videoZoomFactor = 1.0
        }
        device.unlockForConfiguration()
    }

    // MARK: - Recording controls

    func toggleRecording() {
        dataQueue.async { [weak self] in
            guard let self else { return }
            if self.isRecording { self.finishRecording() }
            else { self.beginRecording() }
        }
    }

    private func beginRecording() {
        let (outW, outH) = quality.outputSize

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        guard let w = try? AVAssetWriter(url: url, fileType: .mov) else { return }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.bitRate,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        input.transform = .identity

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outW,
                kCVPixelBufferHeightKey as String: outH
            ])

        guard w.canAdd(input), w.startWriting() else { return }
        w.add(input)

        writer = w
        writerInput = input
        pixelAdaptor = adaptor
        recordingURL = url
        sessionAtSourceTime = false
        DispatchQueue.main.async { self.isRecording = true }
    }

    private func finishRecording() {
        guard let w = writer, isRecording else { return }
        DispatchQueue.main.async { self.isRecording = false }
        writer = nil
        writerInput = nil
        pixelAdaptor = nil

        let url = recordingURL
        recordingURL = nil

        w.finishWriting { [weak self] in
            guard let self, let url, w.status == .completed else { return }
            DispatchQueue.main.async { self.lastVideoURL = url }
            self.saveToLibrary(url)
        }
    }

    private func saveToLibrary(_ url: URL) {
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        } completionHandler: { _, err in
            if let err { print("保存失败: \(err)") }
        }
    }

    // MARK: - Frame processing

    private func processFrame(_ buf: CMSampleBuffer) {
        guard let pixelBuf = CMSampleBufferGetImageBuffer(buf) else { return }

        let ci = CIImage(cvPixelBuffer: pixelBuf).oriented(.right)
        let w = ci.extent.width
        let h = ci.extent.height

        let snap = motionSnapshot()

        smoothRoll  += rollAlpha  * (snap.roll    - smoothRoll)
        smoothOffX  += transAlpha * (snap.offsetX - smoothOffX)
        smoothOffY  += transAlpha * (snap.offsetY - smoothOffY)

        let angle = CGFloat(-smoothRoll)
        let cx = w / 2; let cy = h / 2

        let rotated = ci.transformed(by:
            CGAffineTransform(translationX: -cx, y: -cy)
                .concatenating(CGAffineTransform(rotationAngle: angle))
                .concatenating(CGAffineTransform(translationX: cx, y: cy))
        )

        let re = rotated.extent
        let shorter = min(w, h)
        let cropW = shorter * CGFloat(cropScale)
        let cropH = cropW * CGFloat(1.0 / cropRatio)

        let marginX = max(0, (re.width  - cropW) / 2)
        let marginY = max(0, (re.height - cropH) / 2)

        let cosA = cos(angle); let sinA = sin(angle)
        let rOffX = CGFloat(smoothOffX) * cosA - CGFloat(smoothOffY) * sinA
        let rOffY = CGFloat(smoothOffX) * sinA + CGFloat(smoothOffY) * cosA

        let cropRect = CGRect(
            x: re.midX - cropW / 2 + rOffX * marginX * 0.9,
            y: re.midY - cropH / 2 + rOffY * marginY * 0.9,
            width: cropW, height: cropH
        )

        let result = rotated
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))

        frameIndex += 1

        // 预览 30fps（隔帧发，减少 GPU 负载）
        if frameIndex % 2 == 0 {
            previewFrame?(result)
        }

        // 录制 60fps（每帧都写）
        writeFrame(result, pts: CMSampleBufferGetPresentationTimeStamp(buf))
    }

    private func writeFrame(_ image: CIImage, pts: CMTime) {
        guard let w = writer, let input = writerInput, let adaptor = pixelAdaptor,
              w.status == .writing, input.isReadyForMoreMediaData else { return }

        if !sessionAtSourceTime {
            w.startSession(atSourceTime: pts)
            sessionAtSourceTime = true
        }

        let (outW, outH) = quality.outputSize
        guard let pool = adaptor.pixelBufferPool else { return }
        var outBuf: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf) == kCVReturnSuccess,
              let dest = outBuf else { return }

        // 缩放到输出分辨率
        let scaleX = CGFloat(outW) / image.extent.width
        let scaleY = CGFloat(outH) / image.extent.height
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        ciContext.render(scaled,
                         to: dest,
                         bounds: CGRect(x: 0, y: 0, width: outW, height: outH),
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        adaptor.append(dest, withPresentationTime: pts)
    }
}

// MARK: - Delegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        processFrame(sampleBuffer)
    }
}
