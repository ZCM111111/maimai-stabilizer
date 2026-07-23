import CoreImage
import Metal
import simd

final class FisheyeCorrector {

    var roll: Double = 0, pitch: Double = 0, yaw: Double = 0

    private let dev: MTLDevice
    private let queue: MTLCommandQueue
    private let ps: MTLComputePipelineState

    // 标定参数（竖屏 2160×3840）
    private let calibK: (fx: Float, fy: Float, cx: Float, cy: Float) = (932.7, 936.5, 1111.3, 1846.5)
    private let calibW: Float = 2160, calibH: Float = 3840

    init?() {
        guard let d = MTLCreateSystemDefaultDevice(),
              let q = d.makeCommandQueue() else { return nil }
        self.dev = d; self.queue = q

        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib") else {
            print("❌ default.metallib not found"); return nil
        }
        guard let lib = try? d.makeLibrary(URL: url),
              let fn = lib.makeFunction(name: "stabilize"),
              let p = try? d.makeComputePipelineState(function: fn) else {
            print("❌ kernel not found"); return nil
        }
        self.ps = p
    }

    func correct(_ image: CIImage) -> CIImage? {
        let w = Int(image.extent.width)
        let h = Int(image.extent.height)

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                             width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        guard let inTex = dev.makeTexture(descriptor: desc),
              let outTex = dev.makeTexture(descriptor: desc) else { return nil }

        let ctx = CIContext(mtlDevice: dev, options: [.useSoftwareRenderer: false])
        ctx.render(image, to: inTex, commandBuffer: nil,
                   bounds: image.extent, colorSpace: CGColorSpaceCreateDeviceRGB())

        guard let buf = queue.makeCommandBuffer(),
              let enc = buf.makeComputeCommandEncoder() else { return nil }
        enc.setTexture(inTex, index: 0)
        enc.setTexture(outTex, index: 1)

        // 旋转矩阵: R = Rz(-roll) * Rx(-pitch) * Ry(-yaw)
        // 与 gyroflow live_stab.py 相同的方向：旋转虚拟光线到物理鱼眼坐标系
        let cr = Float(cos(-roll)),  sr = Float(sin(-roll))
        let cp = Float(cos(-pitch)), sp = Float(sin(-pitch))
        let cy = Float(cos(-yaw)),   sy = Float(sin(-yaw))

        var R = simd_float3x3(
            simd_float3(cr*cy + sr*sp*sy, -sr*cp, cr*sy - sr*sp*cy),
            simd_float3(sr*cy - cr*sp*sy,  cr*cp, sr*sy + cr*sp*cy),
            simd_float3(-cp*sy,            sp,    cp*cy)
        )
        enc.setBytes(&R, length: MemoryLayout<simd_float3x3>.size, index: 0)

        // 虚拟相机: 用鱼眼焦距（FOV 与输入相同），居中
        let sx = Float(w) / calibW, sy2 = Float(h) / calibH
        let vfx = calibK.fx * sx, vfy = calibK.fy * sy2
        var cam = SIMD4<Float>(vfx, vfy, Float(w)/2, Float(h)/2)
        enc.setBytes(&cam, length: 16, index: 1)

        // 鱼眼内参
        var fish = SIMD4<Float>(vfx, vfy, calibK.cx * sx, calibK.cy * sy2)
        enc.setBytes(&fish, length: 16, index: 2)

        enc.setComputePipelineState(ps)
        let tw = ps.threadExecutionWidth
        let th = ps.maxTotalThreadsPerThreadgroup / tw
        enc.dispatchThreadgroups(
            MTLSize(width: (w+tw-1)/tw, height: (h+th-1)/th, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        enc.endEncoding()
        buf.commit()
        buf.waitUntilCompleted()

        guard let result = CIImage(mtlTexture: outTex, options: [.colorSpace: CGColorSpaceCreateDeviceRGB() as Any]) else { return nil }
        return result.cropped(to: image.extent)
    }
}
