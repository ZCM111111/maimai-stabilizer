import CoreImage
import Metal

final class FisheyeCorrector {

    var strength: Float = 2.0

    private let dev: MTLDevice
    private let queue: MTLCommandQueue
    private let ps: MTLComputePipelineState

    init?() {
        guard let d = MTLCreateSystemDefaultDevice(),
              let q = d.makeCommandQueue() else { return nil }
        self.dev = d; self.queue = q

        let src = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void correct(texture2d<float, access::read> in [[texture(0)]],
                            texture2d<float, access::write> out [[texture(1)]],
                            constant float4& p [[buffer(0)]],
                            constant float& strength [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
            float fx = p.x, fy = p.y, cx = p.z, cy = p.w;
            float s2 = max(strength, 0.0);
            float kn1 = -0.22327126 * s2, kn2 = 0.04652081 * s2, kn3 = 0.00112181 * s2;
            float kn4 = 0.00183698 * s2, kn5 = -0.00408785 * s2;
            float2 dp = float2(gid) + 0.5;
            float xn = (dp.x - cx) / fx;
            float yn = (dp.y - cy) / fy;
            float r = sqrt(xn*xn + yn*yn);
            float2 sp;
            if (r < 0.001) { sp = dp; }
            else {
                float th = atan(r);
                float th2 = th*th;
                float thd = th*(1.0 + th2*(kn1 + th2*(kn2 + th2*(kn3 + th2*(kn4 + th2*kn5)))));
                float s = thd / r;
                sp = float2(fx*xn*s + cx, fy*yn*s + cy);
            }
            constexpr sampler smp(coord::pixel, address::clamp_to_edge, filter::linear);
            out.write(in.sample(smp, sp), gid);
        }
        """
        guard let lib = try? d.makeLibrary(source: src, options: nil),
              let fn = lib.makeFunction(name: "correct"),
              let p = try? d.makeComputePipelineState(function: fn) else {
            print("❌ Metal shader compile failed")
            return nil
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

        CIContext().render(image, to: inTex, commandBuffer: nil,
                           bounds: image.extent,
                           colorSpace: CGColorSpaceCreateDeviceRGB())

        guard let buf = queue.makeCommandBuffer(),
              let enc = buf.makeComputeCommandEncoder() else { return nil }
        enc.setTexture(inTex, index: 0)
        enc.setTexture(outTex, index: 1)

        var p = SIMD4<Float>(932.7 * Float(w)/2160, 936.5 * Float(h)/3840,
                             1111.3 * Float(w)/2160, 1846.5 * Float(h)/3840)
        var s = strength
        enc.setBytes(&p, length: 16, index: 0)
        enc.setBytes(&s, length: 4, index: 1)
        enc.setComputePipelineState(ps)

        let tw = ps.threadExecutionWidth
        let th = ps.maxTotalThreadsPerThreadgroup / tw
        enc.dispatchThreadgroups(
            MTLSize(width: (w+tw-1)/tw, height: (h+th-1)/th, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        enc.endEncoding()
        buf.commit()
        buf.waitUntilCompleted()

        return CIImage(mtlTexture: outTex,
                       options: [.colorSpace: CGColorSpaceCreateDeviceRGB() as Any])?
            .cropped(to: image.extent)
    }
}
