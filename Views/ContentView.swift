import SwiftUI
import MetalKit
import CoreImage

// MARK: - Content View

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var motion = MotionManager()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            StabilizedPreview(camera: camera)
                .ignoresSafeArea()

            VStack {
                Spacer()
                // 状态指示
                HStack {
                    Circle()
                        .fill(camera.isRunning ? .green : .red)
                        .frame(width: 10, height: 10)
                    Text(camera.isRunning ? "稳定中" : "未启动")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.black.opacity(0.5))
                .clipShape(Capsule())
                .padding(.bottom, 40)
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
    }
}

// MARK: - Metal 渲染的稳像预览

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

        let scaledW = imgW * scale
        let scaledH = imgH * scale
        let tx = (dSize.width  - scaledW) / 2
        let ty = (dSize.height - scaledH) / 2

        let displayed = image.transformed(by:
            CGAffineTransform(scaleX: scale, y: scale)
                .translatedBy(x: tx / scale, y: ty / scale)
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

// MARK: - SwiftUI bridge

private struct StabilizedPreview: UIViewRepresentable {
    let camera: CameraManager

    func makeUIView(context: Context) -> StabilizedMTKView {
        let view = StabilizedMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        camera.previewFrame = { [weak view] ci in
            view?.enqueue(ci)
        }
        return view
    }

    func updateUIView(_ uiView: StabilizedMTKView, context: Context) {}

    static func dismantleUIView(_ uiView: StabilizedMTKView, coordinator: Void) {}
}
