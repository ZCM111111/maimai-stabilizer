//
//  FrameRenderer.swift
//  FisheyeGimbal
//
//  Metal 渲染管线（双段）：
//      CVPixelBuffer(BGRA) --[blit]--> srcTex
//              --[compute FEConvertKernel]--> dstTex(RGBA)
//              --[fragment FEStabilizeFragment]--> drawable
//
//  第二段就是「去畸变 + 三轴增稳」，全部在 GPU 上按反向映射逐像素算，
//  单 pass 完成。1080p60 在 A12 及以上很轻松。
//
//  纹理管理：5 个槽位的环形池，每个槽位带 in-flight 标记。
//  某槽在 GPU 上跑的时候标记占用，command buffer 完成回调里释放。
//  帧率高于处理能力时直接丢帧，绝不阻塞摄像头线程。
//

import Foundation
import Metal
import MetalKit
import CoreVideo
import simd
import QuartzCore

// MARK: - Uniform（必须与 Shaders.metal 的 FEUniforms 严格同布局）
//
// 用「显式 16 字节槽位」而不是一堆散装 float/float2：
// Metal 里 float2 对齐 8、float4 对齐 16，Swift 里 SIMD2<Float> 也对齐 8，
// 两边各自插 padding 就可能错位。全部收进 float4 槽位后，
// 布局是确定性的，不会有分歧。
//
//   offset 0   rawRotation                     (64)
//   offset 64  viewDirW                        (16)
//   offset 80  slots0 = srcSize.xy, outSize.zw (16)
//   offset 96  slots1 = center.xy, focal, fOutX(16)
//   offset 112 slots2 = fOutY, projection, k1, k2 (16)
//   offset 128 slots3 = maxTheta, maxR, feather, exposure (16)
//   offset 144 screenUp_.xy                    (16)
//   总计 160 字节

struct FEUniforms {
    var rawRotation: simd_float4x4 = matrix_identity_float4x4
    var viewDirW: SIMD4<Float> = SIMD4<Float>(0, 0, -1, 0)
    var slots0: SIMD4<Float> = SIMD4<Float>(1920, 1440, 1170, 2532)
    var slots1: SIMD4<Float> = SIMD4<Float>(960, 720, 620, 900)
    var slots2: SIMD4<Float> = SIMD4<Float>(900, 0, 0, 0)
    var slots3: SIMD4<Float> = SIMD4<Float>(1.48, 720, 8, 1)
    var screenUp_: SIMD4<Float> = SIMD4<Float>(0, -1, 0, 0)

    // 便捷存取（只影响 Swift 侧可读性，不改变布局）
    var srcSize: SIMD2<Float> {
        get { SIMD2(slots0.x, slots0.y) }
        set { slots0.x = newValue.x; slots0.y = newValue.y }
    }
    var outSize: SIMD2<Float> {
        get { SIMD2(slots0.z, slots0.w) }
        set { slots0.z = newValue.x; slots0.w = newValue.y }
    }
    var center: SIMD2<Float> {
        get { SIMD2(slots1.x, slots1.y) }
        set { slots1.x = newValue.x; slots1.y = newValue.y }
    }
    var focal: Float {
        get { slots1.z } set { slots1.z = newValue }
    }
    var fOutX: Float {
        get { slots1.w } set { slots1.w = newValue }
    }
    var fOutY: Float {
        get { slots2.x } set { slots2.x = newValue }
    }
    var projection: Float {
        get { slots2.y } set { slots2.y = newValue }
    }
    var k1: Float {
        get { slots2.z } set { slots2.z = newValue }
    }
    var k2: Float {
        get { slots2.w } set { slots2.w = newValue }
    }
    var maxTheta: Float {
        get { slots3.x } set { slots3.x = newValue }
    }
    var maxR: Float {
        get { slots3.y } set { slots3.y = newValue }
    }
    var edgeFeather: Float {
        get { slots3.z } set { slots3.z = newValue }
    }
    var exposure: Float {
        get { slots3.w } set { slots3.w = newValue }
    }
    var screenUp: SIMD2<Float> {
        get { SIMD2(screenUp_.x, screenUp_.y) }
        set { screenUp_.x = newValue.x; screenUp_.y = newValue.y }
    }
}

final class FrameRenderer: NSObject, MTKViewDelegate {

    // MARK: - 依赖

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let convertPSO: MTLComputePipelineState
    private let stabilizePSO: MTLRenderPipelineState
    let params: TunableParams
    let motion: MotionTracker

    // MARK: - 槽位

    private final class Slot {
        let src: MTLTexture
        let dst: MTLTexture
        var inFlight = false
        init(src: MTLTexture, dst: MTLTexture) { self.src = src; self.dst = dst }
    }

    private var slots: [Slot] = []
    private var latestIndex: Int = -1
    private var slotCursor = 0
    private var textureSize: CGSize = .zero
    private let lock = NSLock()
    private let slotCount = 6

    // MARK: - uniform & 统计

    private var uniforms = FEUniforms()
    private var cameraFPS: Double = 0
    private var renderFPS: Double = 0
    private var lastCaptureStamp: Double = 0
    private var lastDrawWall: Double = 0
    private var droppedFrames: Int = 0

    @Published private(set) var hudText: String = ""
    @Published private(set) var sourceSize: CGSize = .zero
    @Published private(set) var motionActive = false

    private weak var mtkView: MTKView?
    private var displayLink: CADisplayLink?

    // MARK: - 初始化

    init?(view: MTKView, motion: MotionTracker, params: TunableParams) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let convertFn = library.makeFunction(name: "FEConvertKernel"),
              let vfn = library.makeFunction(name: "FEStabilizeVertex"),
              let ffn = library.makeFunction(name: "FEStabilizeFragment") else { return nil }

        self.device = device
        self.queue = queue
        self.motion = motion
        self.params = params

        do {
            convertPSO = try device.makeComputePipelineState(function: convertFn)
        } catch { return nil }

        view.colorPixelFormat = .bgra8Unorm
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "FEStabilize"
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        do {
            stabilizePSO = try device.makeRenderPipelineState(descriptor: desc)
        } catch { return nil }

        super.init()

        view.device = device
        view.framebufferOnly = true
        view.isPaused = true              // 由 CADisplayLink 手动驱动
        view.enableSetNeedsDisplay = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = self
        self.mtkView = view

        params.onChange = { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.applyParamsLocked(); self.lock.unlock()
        }
        applyParamsLocked()

        // 布局自检：只对 offset(of:) 断言，不去猜结构体总大小算法。
        // 这些必须和 Shaders.metal 的 [[id(n)]] 一一对应。
        assert(MemoryLayout<FEUniforms>.offset(of: \.rawRotation) == 0)
        assert(MemoryLayout<FEUniforms>.offset(of: \.viewDirW) == 64)
        assert(MemoryLayout<FEUniforms>.offset(of: \.slots0) == 80)
        assert(MemoryLayout<FEUniforms>.offset(of: \.slots1) == 96)
        assert(MemoryLayout<FEUniforms>.offset(of: \.slots2) == 112)
        assert(MemoryLayout<FEUniforms>.offset(of: \.slots3) == 128)
        assert(MemoryLayout<FEUniforms>.offset(of: \.screenUp_) == 144)
    }

    deinit { displayLink?.invalidate() }

    // MARK: - 启动渲染循环

    func startDisplayLink() {
        guard displayLink == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let link = CADisplayLink(target: self, selector: #selector(self.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            self.displayLink = link
        }
    }

    @objc private func tick() {
        mtkView?.draw()
        updateHUD()
    }

    private func updateHUD() {
        let now = CACurrentMediaTime()
        let snap = motion.state.snapshot()
        let fresh = (snap != nil) && (now - (snap?.timestamp ?? 0) < 0.5)
        let s = String(format: "cam %.0f fps · render %.0f fps · imu %@ · drop %d",
                       cameraFPS, renderFPS, fresh ? "ok" : "－", droppedFrames)
        if s != hudText { hudText = s }
        if motionActive != fresh { motionActive = fresh }
    }

    // MARK: - 参数

    /// 调用方必须持有 lock
    private func applyParamsLocked() {
        let w = Float(textureSize.width), h = Float(textureSize.height)
        guard w > 0, h > 0 else { return }
        let shortSide = min(w, h)
        let rMax = shortSide * 0.5
        let norm = shortSide * 0.5

        uniforms.projection = Float(params.projection.rawValue)
        // k1/k2 用「相对半图高」的归一化 r，切分辨率不影响标定结果
        uniforms.k1 = params.k1 * norm * norm
        uniforms.k2 = params.k2 * norm * norm * norm * norm
        uniforms.maxTheta = params.maxHalfFovDeg * .pi / 180
        uniforms.exposure = params.exposure
        uniforms.edgeFeather = params.edgeFeather
        uniforms.maxR = params.imageCircleRadius > 0 ? params.imageCircleRadius : rMax
        uniforms.center = SIMD2<Float>(w * 0.5 + Float(params.centerOffset.x),
                                       h * 0.5 + Float(params.centerOffset.y))
        uniforms.srcSize = SIMD2<Float>(w, h)

        if params.autoFocal {
            uniforms.focal = DistortionModel.focalFromCircle(radius: uniforms.maxR,
                                                             halfFovDeg: params.maxHalfFovDeg)
        } else {
            uniforms.focal = params.focalScale * rMax
        }
        uniforms.screenUp = params.screenUp
    }

    /// 源帧分辨率变化时重建纹理池
    private func rebuildLocked(size: CGSize) {
        slots.removeAll()
        latestIndex = -1
        slotCursor = 0
        textureSize = size
        let w = max(Int(size.width), 16)
        let h = max(Int(size.height), 16)
        for _ in 0..<slotCount {
            guard let src = makeTexture(w, h, .bgra8Unorm),
                  let dst = makeTexture(w, h, .rgba8Unorm) else { continue }
            slots.append(Slot(src: src, dst: dst))
        }
        DispatchQueue.main.async { self.sourceSize = size }
        applyParamsLocked()
    }

    private func makeTexture(_ w: Int, _ h: Int, _ format: MTLPixelFormat) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                         width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    // MARK: - 摄像头帧入口（在 AVCapture 的视频队列上调用）

    func enqueue(_ pixelBuffer: CVPixelBuffer, captureTime: Double) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let size = CGSize(width: w, height: h)

        lock.lock()
        if size != textureSize {
            rebuildLocked(size: size)
        }
        guard !slots.isEmpty else { lock.unlock(); return }

        // 找一个空闲槽
        var idx = -1
        for i in 0..<slots.count {
            let c = (slotCursor + i) % slots.count
            if !slots[c].inFlight { idx = c; break }
        }
        guard idx >= 0 else {
            droppedFrames += 1
            lock.unlock()
            return
        }
        slotCursor = (idx + 1) % slots.count
        let slot = slots[idx]
        slot.inFlight = true
        lock.unlock()

        guard let cmd = queue.makeCommandBuffer() else {
            lock.lock(); slot.inFlight = false; lock.unlock()
            return
        }

        // 把 CVPixelBuffer 拷进私有纹理。
        // 注意：必须用 copy(from: CVPixelBuffer, to: MTLTexture) 这个重载，
        // 不能塞 sourceBytesPerRow / sourceSize 那套参数 —— 那是给 MTLBuffer 源用的。
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: pixelBuffer, to: slot.src)
            blit.endEncoding()
        }

        if let enc = cmd.makeComputeCommandEncoder() {
            enc.label = "FEConvert"
            enc.setComputePipelineState(convertPSO)
            enc.setTexture(slot.src, index: 0)
            enc.setTexture(slot.dst, index: 1)
            enc.dispatchThreadgroups(
                MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            enc.endEncoding()
        }

        cmd.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            slot.inFlight = false
            self.lock.unlock()
        }
        cmd.commit()

        lock.lock()
        latestIndex = idx
        let delta = captureTime - lastCaptureStamp
        lastCaptureStamp = captureTime
        if delta > 0.0001 && delta < 1.0 {
            cameraFPS = cameraFPS == 0 ? 1.0 / delta : (0.9 * cameraFPS + 0.1 * (1.0 / delta))
        }
        lock.unlock()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer() else { return }

        let now = CACurrentMediaTime()
        let drawableSize = view.drawableSize

        lock.lock()
        uniforms.outSize = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        // outputFovDeg 是「横向」视场角：f = (W/2) / tan(hfov/2)，纵横比由 drawable 决定。
        // 竖屏时 drawable 是 W<H，纵向视场角自然比横向小，画面不会被拉伸。
        let fov = Float(params.outputFovDeg) * .pi / 180
        let fOut = (Float(drawableSize.width) * 0.5) / max(tan(fov * 0.5), 1e-3)
        uniforms.fOutX = fOut
        uniforms.fOutY = fOut
        applyParamsLocked()

        // ---- 姿态补偿 -> 源帧坐标系基底 ----
        // sensor +x -> 纹理 +u，sensor +y -> 纹理 +v，光轴(朝外) -> 纹理 -(u×v)
        // rawRotation 的列就是源帧三轴在世界系中的方向；再叠加 m.compensation。
        if let snap = motion.state.snapshot() {
            let m = simd_float3x3(snap.compensation)
            let axisU = m.columns.0      // 纹理 +u = sensor +x 在世界系中的方向
            let axisV = -m.columns.1     // 纹理 +v = sensor -y
            let axisW = -m.columns.2     // 纹理 -(u×v) = 光轴朝外 = sensor -z
            uniforms.rawRotation = simd_float4x4(columns: (
                SIMD4<Float>(axisU, 0),
                SIMD4<Float>(axisV, 0),
                SIMD4<Float>(axisW, 0),
                SIMD4<Float>(0, 0, 0, 1)
            ))
            // 锁定方向永远等于「开锁那一刻的光轴」，在源帧坐标系里就是 (0,0,-1)
            uniforms.viewDirW = SIMD4<Float>(0, 0, -1, 0)
        }
        var u = uniforms
        let idx = latestIndex
        var tex: MTLTexture?
        if idx >= 0, idx < slots.count {
            tex = slots[idx].dst
            // 关键：把这一槽占住，直到本帧显示用的 command buffer 结束。
            // 否则新到的摄像头帧可能复用它，GPU 上出现「读的同时在写」→ 画面撕裂/闪白。
            slots[idx].inFlight = true
        }
        lock.unlock()

        let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)
        enc?.label = "FEStabilize"
        if let enc, let tex {
            enc.setRenderPipelineState(stabilizePSO)
            enc.setVertexBytes(&u, length: MemoryLayout<FEUniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<FEUniforms>.stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc?.endEncoding()
        cmd.present(drawable)
        cmd.addCompletedHandler { [weak self] _ in
            guard let self, idx >= 0 else { return }
            self.lock.lock()
            if idx < self.slots.count { self.slots[idx].inFlight = false }
            self.lock.unlock()
        }
        cmd.commit()

        if lastDrawWall > 0 {
            let d = now - lastDrawWall
            if d > 0.0001 && d < 1.0 {
                let f = 1.0 / d
                renderFPS = renderFPS == 0 ? f : (0.9 * renderFPS + 0.1 * f)
            }
        }
        lastDrawWall = now
    }
}

// MARK: - 屏幕方向 -> 源帧平面内的"屏幕上方"方向
//
// 源帧纹理坐标：u 沿宽度、v 沿高度。
//  - 竖屏持机：屏幕上 = 纹理 -v  -> (0, -1)
//  - 左横屏  ：屏幕上 = 纹理 +u  -> (1, 0)
//  - 右横屏  ：屏幕上 = 纹理 -u  -> (-1, 0)
//
// 这个轴和「设备姿态」无关（因为相机传感器固定装在机身上），
// 所以只需要跟着界面方向切，不需要每帧算。
extension UIInterfaceOrientation {
    var feScreenUp: SIMD2<Float> {
        switch self {
        case .portraitUpsideDown: return SIMD2<Float>(0, 1)
        case .landscapeLeft:      return SIMD2<Float>(1, 0)
        case .landscapeRight:     return SIMD2<Float>(-1, 0)
        default:                  return SIMD2<Float>(0, -1)   // portrait
        }
    }
}
