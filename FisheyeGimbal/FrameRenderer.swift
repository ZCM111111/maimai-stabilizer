//
//  FrameRenderer.swift
//  FisheyeGimbal
//
//  Metal 渲染管线（双段）：
//      CVPixelBuffer(BGRA) --[CVMetalTextureCache 零拷贝]--> srcTex
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
        /// 转换结果：RGBA，给 fragment shader 采样。
        /// 不在槽之间流转 —— 每个槽固定持有自己的纹理，谁都不搬。
        var dst: MTLTexture?
        /// 本槽当前占用的 CVPixelBuffer 包装（BGRA 1 个 / YUV 2 个）。
        /// 必须持有到 GPU 用完为止，否则 buffer 被回收后纹理内容失效。
        var srcWrappers: [CVMetalTexture] = []
        /// 本槽正被 GPU（转换或显示）使用中
        var busy = false
        init() {}
    }

    private var slots: [Slot] = []
    /// 旧槽位退役区：rebuild 时不立刻销毁，先挂这里，
    /// 让正在飞行中的 draw（可能还指着旧 idx）安全读到。
    private var retiredSlots: [[Slot]] = []
    /// 最近一帧的槽索引，以及该槽是否正被显示占用
    private var latestIndex: Int = -1
    private var latestSlotBusy = false
    private var slotCursor = 0
    private var textureSize: CGSize = .zero
    private let lock = NSLock()
    private let slotCount = 6
    /// 纹理尺寸累计重建次数（诊断用）
    private var rebuildCount = 0

    /// CVPixelBuffer -> MTLTexture 的零拷贝缓存。
    /// 比 blit 拷贝快，而且不用维护源纹理池。
    private var textureCache: CVMetalTextureCache?

    /// 诊断用：最近一帧到达的时刻、像素格式、被丢掉的格式不符帧数
    /// （这三个在 enqueue 里赋值、在 updateHUD 里读取，都受 lock 保护）
    private var lastFrameWall: Double = 0
    private var lastPixelFormat: OSType = 0
    private var unsupportedFormatFrames = 0
    /// 进入 enqueue 的帧数（用来确认摄像头帧到底有没有到渲染器）
    private var enqueuedFrames = 0
    /// 绘制阶段诊断
    private var drawEncodeCount = 0
    private var drawEncodedOK = false
    private var lastDrawHadTexture = false
    private var lastDrawIndex = -1
    private var lastDrawableSize: CGSize = .zero
    /// 失败原因（noDrawable / noRPD / noCmdBuf / encoderNil / noTexture）
    private var failReason = "无"
    /// render pass 颜色附件纹理格式 与 view 声明格式（两者不一致会导致 encoder 创建失败）
    private var rpdFormat = "?"
    private var viewFormat = "?"
    /// MTKView 实际几何（判断 drawable 为 0 是不是因为 view 本身没尺寸）

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

        // CVPixelBuffer -> MTLTexture 的零拷贝缓存
        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault,
                                                    nil,
                                                    device,
                                                    nil,
                                                    &cache)
        if cacheStatus == kCVReturnSuccess {
            self.textureCache = cache
        }

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

        lock.lock()
        let lastArrival = lastFrameWall
        let fmt = lastPixelFormat
        let unsupported = unsupportedFormatFrames
        let localFPS = cameraFPS
        let arrivedFrames = enqueuedFrames
        let draws = drawEncodeCount
        let encodedOK = drawEncodedOK
        let hadTex = lastDrawHadTexture
        let drewIdx = lastDrawIndex
        let dSize = lastDrawableSize
        let slotN = slots.count
        // 注意：这里是在 lock 保护下取的快照计数，
        // 不要在锁外用 filter 遍历 slots —— 那会在 rebuild 时读到半个数组。
        var nilTex = 0
        for s in slots where s.dst == nil { nilTex += 1 }
        let rebuilds = rebuildCount
        let why = failReason
        let rf = rpdFormat
        let vf = viewFormat
        lock.unlock()

        // 帧到达情况：超过 0.5 秒没新帧就算断了
        let frameArriving = lastArrival > 0 && (now - lastArrival) < 0.5
        let supported: [OSType] = [
            kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        let stage: String
        if lastArrival == 0 {
            stage = "无帧"
        } else if !frameArriving {
            stage = String(format: "断流%.0fs", now - lastArrival)
        } else if !supported.contains(fmt) {
            stage = "格式不支持"        // 帧在到，但像素格式我们转不了
        } else if localFPS < 1 {
            stage = "刚起帧"
        } else {
            stage = "ok"
        }

        // 四字符格式码，例如 BGRA / 420f（YUV 全范围）/ 420v
        let fcc = Self.fourCC(fmt)
        // 用字符串插值而不是 String(format:)，避免手工数占位符数错（已经栽过两次）
        let s = "arr\(arrivedFrames) fps\(Int(localFPS)) \(stage) \(fcc) lost\(droppedFrames + unsupported)"
            + " | draw\(draws) \(encodedOK ? "ok" : "FAIL") idx\(drewIdx)/\(slotN)"
            + " tex\(hadTex ? "Y" : "N") nil\(nilTex) rb\(rebuilds)"
            + " dw\(Int(dSize.width))x\(Int(dSize.height)) rpd\(rf)/v\(vf) why=\(why)"

        if s != hudText { hudText = s }
        if motionActive != fresh { motionActive = fresh }
    }

    /// OSType -> 可读的四字符码
    static func fourCC(_ code: OSType) -> String {
        guard code != 0 else { return "----" }
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        let scalars = bytes.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "?" }
        return String(scalars)
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
        // screenUp_.z 同时打包两个诊断开关：高 16 位=测试图，低 16 位=姿态旁路
        let diagBits: UInt32 = ((params.showTestPattern ? 1 : 0) << 16)
                             | (params.poseBypass ? 1 : 0)
        uniforms.screenUp_.z = Float(bitPattern: diagBits)
    }

    /// 源帧分辨率变化时重建纹理池。
    /// 每个槽固定持有自己的纹理，之后再不流转 —— 避免"谁搬到谁"的记账错误。
    private func rebuildLocked(size: CGSize) {
        // 已经建过同样尺寸就别重建（防重复重建把画面打断）
        if !slots.isEmpty && size == textureSize { return }

        // 旧槽位不立即销毁：draw 可能还指着旧 idx，直接清空会读到悬空槽
        if !slots.isEmpty {
            retiredSlots.append(slots)
            if retiredSlots.count > 2 { retiredSlots.removeFirst() }
        }
        slots.removeAll()
        latestIndex = -1
        latestSlotBusy = false
        slotCursor = 0
        textureSize = size
        rebuildCount += 1
        let w = max(Int(size.width), 16)
        let h = max(Int(size.height), 16)
        for _ in 0..<slotCount {
            let slot = Slot()
            slot.dst = makeTexture(w, h, .rgba8Unorm)
            slots.append(slot)
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

    /// 零拷贝：把 CVPixelBuffer 包成 Metal 纹理。
    /// 单平面(BGRA)只填 textures[0]；BiPlanar(YUV420) 填 textures[0]=Y、[1]=CbCr。
    /// 返回的包装必须一直持有到 GPU 用完，否则 buffer 回收后纹理内容失效。
    private struct SourceTextures {
        var textures: [MTLTexture] = []
        var wrappers: [CVMetalTexture] = []
        var format: UInt32 = 0        // 0=BGRA 1=YUV420f 2=YUV420v
    }

    private func makeSourceTextures(from pixelBuffer: CVPixelBuffer,
                                    width: Int, height: Int) -> SourceTextures? {
        guard let cache = textureCache else { return nil }
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        var out = SourceTextures()

        switch fmt {
        case kCVPixelFormatType_32BGRA:
            if let t = wrapPlane(pixelBuffer, cache, .bgra8Unorm, width, height, 0) {
                out.textures = [t.0]; out.wrappers = [t.1]; out.format = 0
            }
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            // Y 平面 = r8Unorm；CbCr 交错平面 = rg8Unorm，尺寸减半
            if let y = wrapPlane(pixelBuffer, cache, .r8Unorm, width, height, 0),
               let uv = wrapPlane(pixelBuffer, cache, .rg8Unorm, width / 2, height / 2, 1) {
                out.textures = [y.0, uv.0]; out.wrappers = [y.1, uv.1]; out.format = 1
            }
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            if let y = wrapPlane(pixelBuffer, cache, .r8Unorm, width, height, 0),
               let uv = wrapPlane(pixelBuffer, cache, .rg8Unorm, width / 2, height / 2, 1) {
                out.textures = [y.0, uv.0]; out.wrappers = [y.1, uv.1]; out.format = 2
            }
        default:
            return nil
        }
        return out.textures.isEmpty ? nil : out
    }

    private func wrapPlane(_ pixelBuffer: CVPixelBuffer,
                           _ cache: CVMetalTextureCache,
                           _ format: MTLPixelFormat,
                           _ w: Int, _ h: Int, _ plane: Int) -> (MTLTexture, CVMetalTexture)? {
        guard w > 0, h > 0 else { return nil }
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, format, w, h, plane, &cvTex)
        guard status == kCVReturnSuccess, let cvTex,
              let mtl = CVMetalTextureGetTexture(cvTex) else { return nil }
        return (mtl, cvTex)
    }

    // MARK: - 摄像头帧入口（在 AVCapture 的视频队列上调用）

    func enqueue(_ pixelBuffer: CVPixelBuffer, captureTime: Double) {
        // 先记录"帧到了"——放在所有 guard 之前，
        // 这样 HUD 能区分「摄像头没出帧」和「帧到了但被我们丢掉」。
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let size = CGSize(width: w, height: h)

        lock.lock()
        lastFrameWall = CACurrentMediaTime()
        lastPixelFormat = fmt
        enqueuedFrames += 1
        lock.unlock()

        // 只接受我们确实能转成 RGBA 的格式（BGRA / YUV420 双平面）
        let supported: [OSType] = [
            kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        guard supported.contains(fmt) else {
            lock.lock(); unsupportedFormatFrames += 1; lock.unlock()
            return
        }

        lock.lock()
        if size != textureSize {
            rebuildLocked(size: size)
        }
        guard !slots.isEmpty else { lock.unlock(); return }

        // 找一个不忙的槽（显示占用或转换中的都跳过）
        var idx = -1
        for i in 0..<slots.count {
            let c = (slotCursor + i) % slots.count
            if !slots[c].busy { idx = c; break }
        }
        guard idx >= 0 else {
            droppedFrames += 1
            lock.unlock()
            return
        }
        slotCursor = (idx + 1) % slots.count
        let slot = slots[idx]
        slot.busy = true
        guard let dstTex = slot.dst else {
            slot.busy = false
            lock.unlock()
            return
        }
        lock.unlock()

        // 零拷贝拿源纹理（BGRA 单平面 或 YUV420 双平面）
        guard let src = makeSourceTextures(from: pixelBuffer, width: w, height: h) else {
            lock.lock(); slot.busy = false; lock.unlock()
            return
        }
        lock.lock()
        slot.srcWrappers = src.wrappers
        let srcFormat = src.format
        lock.unlock()

        guard let cmd = queue.makeCommandBuffer() else {
            lock.lock(); slot.busy = false; slot.srcWrappers = []; lock.unlock()
            return
        }

        if let enc = cmd.makeComputeCommandEncoder() {
            enc.label = "FEConvert"
            enc.setComputePipelineState(convertPSO)
            // 单平面源只读 textures[0]；YUV 读 [0]=Y、[1]=CbCr。
            // 用同一张纹理填坑不会出错：shader 只读它需要的那些。
            let plane0 = src.textures[0]
            let plane1 = src.textures.count > 1 ? src.textures[1] : plane0
            enc.setTexture(plane0, index: 0)
            enc.setTexture(plane1, index: 1)
            enc.setTexture(plane0, index: 2)
            enc.setTexture(dstTex, index: 3)
            var fmt32 = srcFormat
            enc.setBytes(&fmt32, length: MemoryLayout<UInt32>.size, index: 0)
            enc.dispatchThreadgroups(
                MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            enc.endEncoding()
        }

        cmd.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            // 必须等 GPU 用完才能放掉 buffer 包装
            self.lock.lock()
            slot.busy = false
            slot.srcWrappers = []
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
        guard let drawable = view.currentDrawable else {
            lock.lock(); failReason = "noDrawable"; lock.unlock()
            return
        }
        guard let rpd = view.currentRenderPassDescriptor else {
            lock.lock(); failReason = "noRPD"; lock.unlock()
            return
        }
        guard let cmd = queue.makeCommandBuffer() else {
            lock.lock(); failReason = "noCmdBuf"; lock.unlock()
            return
        }

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
        if idx >= 0, idx < slots.count, let t = slots[idx].dst {
            tex = t
            // 关键：把这一槽占住，直到本帧显示用的 command buffer 结束。
            // 否则新到的摄像头帧可能复用它，GPU 上出现「读的同时在写」→ 撕裂。
            slots[idx].busy = true
            latestSlotBusy = true
        }
        // 诊断：记录这一帧的实际状态
        lastDrawHadTexture = (tex != nil)
        lastDrawIndex = idx
        lastDrawableSize = drawableSize
        let texFmt = rpd.colorAttachments[0].texture?.pixelFormat
        let rpdFmtText: String
        if let texFmt {
            rpdFmtText = "\(texFmt.rawValue)"
        } else {
            rpdFmtText = "无纹理"
        }
        rpdFormat = rpdFmtText
        viewFormat = "\(view.colorPixelFormat.rawValue)"
        lock.unlock()

        let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)
        enc?.label = "FEStabilize"
        var encoded = false
        var localReason = ""
        if enc == nil {
            localReason = "encoderNil"
        } else if let tex {
            enc!.setRenderPipelineState(stabilizePSO)
            enc!.setVertexBytes(&u, length: MemoryLayout<FEUniforms>.stride, index: 0)
            enc!.setFragmentBytes(&u, length: MemoryLayout<FEUniforms>.stride, index: 0)
            enc!.setFragmentTexture(tex, index: 0)
            enc!.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoded = true
        } else {
            localReason = "noTexture"
        }
        enc?.endEncoding()

        lock.lock()
        drawEncodedOK = encoded
        drawEncodeCount += 1
        // 成功时必须清掉旧原因，否则 HUD 会一直显示历史的失败原因，误导排查
        failReason = localReason.isEmpty ? "ok" : localReason
        lock.unlock()

        cmd.present(drawable)
        let releaseIdx = encoded ? idx : -1
        cmd.addCompletedHandler { [weak self] _ in
            guard let self, releaseIdx >= 0 else { return }
            self.lock.lock()
            if releaseIdx < self.slots.count { self.slots[releaseIdx].busy = false }
            self.latestSlotBusy = false
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
