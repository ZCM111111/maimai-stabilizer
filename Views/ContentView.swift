import SwiftUI
import MetalKit
import CoreImage
import AVKit

// MARK: - Content View

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var motion = MotionManager()
    @State private var showingPlayer = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            StabilizedPreview(camera: camera)
                .ignoresSafeArea()

            VStack {
                Spacer()

                // ── 底部控制栏 ──
                VStack(spacing: 12) {
                    // 画质选择
                    Picker("画质", selection: $camera.quality) {
                        ForEach(RecordingQuality.allCases) { q in
                            Text(q.rawValue).tag(q)
                        }
                    }
                    .pickerStyle(.segmented)
                    .colorMultiply(.white)
                    .padding(.horizontal, 40)

                    HStack(spacing: 40) {
                        // 相册预览
                        Button {
                            if camera.lastVideoURL != nil { showingPlayer = true }
                        } label: {
                            thumbnailView
                        }

                        // 录制按钮
                        Button { camera.toggleRecording() } label: {
                            ZStack {
                                Circle()
                                    .strokeBorder(.white, lineWidth: 4)
                                    .frame(width: 72, height: 72)
                                if camera.isRecording {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(.red)
                                        .frame(width: 30, height: 30)
                                } else {
                                    Circle()
                                        .fill(.red)
                                        .frame(width: 58, height: 58)
                                }
                            }
                        }

                        // 占位
                        Color.clear.frame(width: 54, height: 54)
                    }

                    // 状态
                    HStack(spacing: 8) {
                        Circle()
                            .fill(camera.isRecording ? .red : (camera.isRunning ? .green : .gray))
                            .frame(width: 8, height: 8)
                        Text(camera.isRecording ? "● REC"
                               : (camera.isRunning ? "稳定中" : "启动中..."))
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    .padding(.bottom, 8)
                }
                .padding(.vertical, 16)
                .background(.ultraThinMaterial)
            }
        }
        .onAppear {
            camera.motionSnapshot = { [weak motion] in
                motion?.snapshot() ?? (0, 0, 0)
            }
            camera.start()
            motion.start()
        }
        .onDisappear {
            camera.stop()
            motion.stop()
        }
        .fullScreenCover(isPresented: $showingPlayer) {
            if let url = camera.lastVideoURL {
                VideoPlayerView(url: url)
            }
        }
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnailView: some View {
        if let url = camera.lastVideoURL {
            VideoThumbnail(url: url)
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(.white.opacity(0.15))
                .frame(width: 54, height: 54)
                .overlay(
                    Image(systemName: "video.fill")
                        .foregroundStyle(.white.opacity(0.5))
                )
        }
    }
}

// MARK: - Metal 稳像预览

private final class StabilizedMTKView: MTKView {
    private let ciContext: CIContext
    private let cmdQueue: MTLCommandQueue
    private var latestImage: CIImage?
    private let renderLock = NSLock()
    private var displayLink: CADisplayLink?

    override init(frame: CGRect, device: MTLDevice?) {
        let dev = device ?? MTLCreateSystemDefaultDevice()!
        cmdQueue = dev.makeCommandQueue()!
        ciContext = CIContext(mtlDevice: dev, options: [
            .useSoftwareRenderer: false,
            .workingColorSpace: CGColorSpaceCreateDeviceRGB() as Any
        ])
        super.init(frame: frame, device: dev)
        framebufferOnly = false
        enableSetNeedsDisplay = false
        isPaused = true
        backgroundColor = .black
        autoResizeDrawable = true

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    required init(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let screen = window?.windowScene?.screen {
            contentScaleFactor = screen.scale
        }
    }

    deinit { displayLink?.invalidate() }

    func enqueue(_ image: CIImage) {
        renderLock.lock()
        latestImage = image
        renderLock.unlock()
    }

    @objc private func tick(_ link: CADisplayLink) {
        renderLock.lock()
        let has = latestImage != nil
        renderLock.unlock()
        if has { draw() }
    }

    override func draw(_ rect: CGRect) {
        renderLock.lock()
        let image = latestImage
        renderLock.unlock()
        guard let image,
              let cmdBuf = cmdQueue.makeCommandBuffer(),
              let drawable = currentDrawable else { return }

        let dSize = CGSize(width: drawableSize.width, height: drawableSize.height)
        let imgW = image.extent.width
        let imgH = image.extent.height
        let scale = min(dSize.width / imgW, dSize.height / imgH)

        let displayed = image.transformed(by:
            CGAffineTransform(scaleX: scale, y: scale)
                .translatedBy(
                    x: (dSize.width / scale - imgW) / 2,
                    y: (dSize.height / scale - imgH) / 2
                )
        )

        let dest = CIRenderDestination(
            width: Int(dSize.width), height: Int(dSize.height),
            pixelFormat: colorPixelFormat,
            commandBuffer: cmdBuf
        ) { [weak drawable] in drawable!.texture }
        dest.isFlipped = true

        _ = try? ciContext.startTask(toClear: dest)
        _ = try? ciContext.startTask(toRender: displayed, to: dest)

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}

private struct StabilizedPreview: UIViewRepresentable {
    let camera: CameraManager

    func makeUIView(context: Context) -> StabilizedMTKView {
        let view = StabilizedMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        camera.previewFrame = { [weak view] ci in view?.enqueue(ci) }
        return view
    }

    func updateUIView(_ uiView: StabilizedMTKView, context: Context) {}

    static func dismantleUIView(_ uiView: StabilizedMTKView, coordinator: Void) {}
}

// MARK: - Video Thumbnail

private struct VideoThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 2)
                    )
            } else {
                Color.clear
            }
        }
        .onAppear {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 120, height: 120)
            gen.generateCGImageAsynchronously(for: CMTime(seconds: 0.1, preferredTimescale: 600)) { cg, _, _ in
                if let cg {
                    DispatchQueue.main.async { self.image = UIImage(cgImage: cg) }
                }
            }
        }
    }
}

// MARK: - Video Player

private struct VideoPlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player).ignoresSafeArea()
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white, .black.opacity(0.5))
                    .padding(20)
            }
        }
        .onAppear {
            let p = AVPlayer(url: url); player = p; p.play()
        }
        .onDisappear { player?.pause() }
    }
}
