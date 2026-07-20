import AVFoundation
import CoreImage
import CoreVideo
import Photos
import UIKit

// MARK: - Recording Quality

enum RecordingQuality: String, CaseIterable, Identifiable {
    case hd1080p60 = "1080p 60fps"
    case k4k60     = "4K 60fps"
    var id: String { rawValue }
}

// MARK: - Camera Manager

final class CameraManager: NSObject, ObservableObject {

    // MARK: - Session

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "maimai.session")
    private var isConfigured = false

    // MARK: - Inputs

    private var videoDeviceInput: AVCaptureDeviceInput?

    // MARK: - Data output

    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let dataOutputQueue = DispatchQueue(label: "maimai.data", qos: .userInteractive)

    // MARK: - Writer (all accessed exclusively on dataOutputQueue)

    nonisolated(unsafe) private var assetWriter: AVAssetWriter?
    nonisolated(unsafe) private var videoWriterInput: AVAssetWriterInput?
    nonisolated(unsafe) private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    nonisolated(unsafe) private var recordingURL: URL?
    nonisolated(unsafe) private var sessionAtSourceTime = false
    nonisolated(unsafe) private var isRecordingFlag = false
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Smoothing state (accessed only on dataOutputQueue)

    nonisolated(unsafe) private var smoothedRoll:  Double = 0.0
    nonisolated(unsafe) private var smoothedNormX: Double = 0.0
    nonisolated(unsafe) private var smoothedNormY: Double = 0.0

    // MARK: - Published state

    @Published var permissionDenied = false
    @Published var isRecording = false
    @Published var lastVideoURL: URL?
    @Published var isRunning = false
    @Published var quality: RecordingQuality = .hd1080p60

    // MARK: - Motion snapshot provider

    nonisolated(unsafe) var motionSnapshotProvider: () -> (roll: Double, offsetX: Double, offsetY: Double) = { (0, 0, 0) }

    // MARK: - Preview frame handler

    nonisolated(unsafe) var previewFrameHandler: ((CIImage) -> Void)? = nil

    // Fisheye
    private let fisheye = FisheyeCorrector()
    @Published var fisheyeOn = false
    @Published var fisheyeStrength: Float = 2.0 {
        didSet { fisheye?.strength = fisheyeStrength }
    }

    // MARK: - Crop geometry

    private let cropFraction: Double = 3.0 / 5.0 * 0.90
    private let cropAspectW: Double  = 3.0
    private let cropAspectH: Double  = 4.0

    // MARK: - Lifecycle

    func start() {
        // 提前申请相册权限
        if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:    startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                if ok { self?.startSession() }
                else  { DispatchQueue.main.async { self?.permissionDenied = true } }
            }
        default:
            DispatchQueue.main.async { self.permissionDenied = true }
        }
    }

    func stop() {
        dataOutputQueue.async { [weak self] in
            guard let self else { return }
            if self.isRecordingFlag { self.stopRecording() }
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
        DispatchQueue.main.async { self.isRunning = false }
    }

    private func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured { self.configureSession() }
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.isRunning = true }
        }
    }

    // MARK: - Session Config

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        defer { session.commitConfiguration(); isConfigured = true }

        guard let device = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input  = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        videoDeviceInput = input

        try? device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus)       { device.focusMode    = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        device.unlockForConfiguration()

        enforceFourByThreeAndMinZoom()

        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoDataOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)
        guard session.canAddOutput(videoDataOutput) else { return }
        session.addOutput(videoDataOutput)

        // 硬件防抖
        if let conn = videoDataOutput.connection(with: .video), conn.isVideoStabilizationSupported {
            if #available(iOS 18.0, *) {
                conn.preferredVideoStabilizationMode = .cinematicExtendedEnhanced
            } else {
                conn.preferredVideoStabilizationMode = .cinematicExtended
            }
        }
    }

    // MARK: - 4:3 + 60fps

    private func best4by3Format(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let target = 4.0 / 3.0
        var best60: AVCaptureDevice.Format?; var bestW60: Int32 = 0
        var best30: AVCaptureDevice.Format?; var bestW30: Int32 = 0
        for fmt in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            guard d.width > 0, d.height > 0 else { continue }
            guard abs(Double(d.width) / Double(d.height) - target) < 0.01 else { continue }
            let maxFPS = fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            guard maxFPS >= 30 else { continue }
            if maxFPS >= 60 {
                if d.width > bestW60 { best60 = fmt; bestW60 = d.width }
            } else {
                if d.width > bestW30 { best30 = fmt; bestW30 = d.width }
            }
        }
        return best60 ?? best30
    }

    private func enforceFourByThreeAndMinZoom() {
        guard let device = videoDeviceInput?.device else { return }
        session.sessionPreset = .inputPriority
        do {
            try device.lockForConfiguration()
            if let fmt = best4by3Format(for: device) {
                device.activeFormat = fmt
                let maxFPS = fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
                let fps: Int32 = maxFPS >= 60 ? 60 : 30
                let dur = CMTime(value: 1, timescale: fps)
                device.activeVideoMinFrameDuration = dur
                device.activeVideoMaxFrameDuration = dur
            }
            if #available(iOS 17.0, *) {
                device.videoZoomFactor = max(1.0, device.minAvailableVideoZoomFactor)
            } else {
                device.videoZoomFactor = 1.0
            }
            device.unlockForConfiguration()
        } catch { print("Config error:", error) }
    }

    // MARK: - Recording

    func toggleRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let dims: CMVideoDimensions
            if let device = self.videoDeviceInput?.device {
                dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            } else {
                dims = CMVideoDimensions(width: 1920, height: 1080)
            }

            self.dataOutputQueue.async {
                if self.isRecordingFlag {
                    self.stopRecording()
                } else {
                    let sensorShort = Double(min(dims.width, dims.height))
                    let cropW_d     = sensorShort * self.cropFraction
                    let cropH_d     = cropW_d * (self.cropAspectH / self.cropAspectW)
                    let outW = max(2, Int(cropW_d) & ~1)
                    let outH = max(2, Int(cropH_d) & ~1)
                    self.startRecording(outW: outW, outH: outH)
                }
            }
        }
    }

    /// Must be called on dataOutputQueue.
    private func startRecording(outW: Int, outH: Int) {
        guard !isRecordingFlag, outW > 0, outH > 0 else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        guard let writer = try? AVAssetWriter(url: url, fileType: .mov) else {
            print("❌ AVAssetWriter 创建失败"); return
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey:      10_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30
            ]
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        vInput.transform = .identity

        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey           as String: outW,
            kCVPixelBufferHeightKey          as String: outH
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput, sourcePixelBufferAttributes: adaptorAttrs)

        guard writer.canAdd(vInput) else { print("❌ cannot add input"); return }
        writer.add(vInput)
        guard writer.startWriting() else { print("❌ startWriting failed:", writer.error as Any); return }

        assetWriter        = writer
        videoWriterInput   = vInput
        pixelBufferAdaptor = adaptor
        recordingURL       = url
        sessionAtSourceTime = false
        isRecordingFlag    = true
        DispatchQueue.main.async { self.isRecording = true }
    }

    /// Must be called on dataOutputQueue.
    private func stopRecording() {
        guard isRecordingFlag, let writer = assetWriter else { return }

        isRecordingFlag    = false
        assetWriter        = nil
        videoWriterInput   = nil
        pixelBufferAdaptor = nil
        DispatchQueue.main.async { self.isRecording = false }

        let url = recordingURL
        recordingURL = nil
        writer.finishWriting {
            guard let url, writer.status == .completed else { return }
            DispatchQueue.main.async { self.lastVideoURL = url }
            self.saveVideoToLibrary(url: url)
        }
    }

    private func saveVideoToLibrary(url: URL) {
        let save = {
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { _, error in
                if let error { print("Save error:", error) }
            }
        }
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited: save()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { s in
                if s == .authorized || s == .limited { save() }
            }
        default: break
        }
    }

    // MARK: - Frame processing

    private let rollSmoothingAlpha: Double        = 0.25
    private let translationSmoothingAlpha: Double = 0.10

    /// Called on dataOutputQueue by captureOutput.
    nonisolated private func processVideoFrame(_ sampleBuffer: CMSampleBuffer) {

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let raw = CIImage(cvPixelBuffer: pixelBuffer)
        let corrected: CIImage
        if fisheyeOn, let c = fisheye?.correct(raw) { corrected = c }
        else { corrected = raw }
        let ciImage = corrected.oriented(.right)
        let pW: CGFloat = ciImage.extent.width
        let pH: CGFloat = ciImage.extent.height

        let snap = motionSnapshotProvider()

        smoothedRoll  += rollSmoothingAlpha        * (snap.roll    - smoothedRoll)
        smoothedNormX += translationSmoothingAlpha * (snap.offsetX - smoothedNormX)
        smoothedNormY += translationSmoothingAlpha * (snap.offsetY - smoothedNormY)

        let angle: CGFloat = CGFloat(-smoothedRoll)
        let cx = pW / 2;  let cy = pH / 2

        let centreRotation = CGAffineTransform(translationX: -cx, y: -cy)
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX:  cx, y:  cy))
        let rotated = ciImage.transformed(by: centreRotation)

        let re = rotated.extent
        let shorter: CGFloat = min(pW, pH)
        let cropW: CGFloat   = shorter * CGFloat(cropFraction)
        let cropH: CGFloat   = cropW   * CGFloat(cropAspectH / cropAspectW)

        let marginX = max(0, (re.width  - cropW) / 2)
        let marginY = max(0, (re.height - cropH) / 2)

        let cosA = cos(angle);  let sinA = sin(angle)
        let rotNormX = CGFloat(smoothedNormX) * cosA - CGFloat(smoothedNormY) * sinA
        let rotNormY = CGFloat(smoothedNormX) * sinA + CGFloat(smoothedNormY) * cosA

        let shiftX = rotNormX * marginX * 0.9
        let shiftY = rotNormY * marginY * 0.9

        let cropRect = CGRect(
            x: re.midX - cropW / 2 + shiftX,
            y: re.midY - cropH / 2 + shiftY,
            width:  cropW,
            height: cropH
        )

        let cropped = rotated
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX,
                                               y:            -cropRect.minY))

        previewFrameHandler?(cropped)

        guard isRecordingFlag,
              let writer  = assetWriter,
              let vInput  = videoWriterInput,
              let adaptor = pixelBufferAdaptor,
              writer.status == .writing,
              vInput.isReadyForMoreMediaData else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionAtSourceTime {
            writer.startSession(atSourceTime: pts)
            sessionAtSourceTime = true
        }

        guard let pool = adaptor.pixelBufferPool else { return }
        var outBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer) == kCVReturnSuccess,
              let destBuffer = outBuffer else { return }

        let renderW = Int(cropRect.width)  & ~1
        let renderH = Int(cropRect.height) & ~1
        ciContext.render(cropped,
                         to: destBuffer,
                         bounds: CGRect(x: 0, y: 0, width: renderW, height: renderH),
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        adaptor.append(destBuffer, withPresentationTime: pts)
    }
}

// MARK: - Delegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            processVideoFrame(sampleBuffer)
        }
    }
}

// MARK: - Quality bit rates

extension RecordingQuality {
    var bitRate: Int {
        switch self {
        case .hd1080p60: return 20_000_000
        case .k4k60:      return 50_000_000
        }
    }
}
