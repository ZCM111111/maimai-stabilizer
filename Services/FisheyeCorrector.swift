import CoreImage
import Metal

/// Metal shader 鱼眼矫正（绕过 CIKernel sampler 问题）
final class FisheyeCorrector {

    private let pipeline: MTLComputePipelineState
    private let device: MTLDevice

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = dev

        let src = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void fisheye(texture2d<float, access::read> in [[texture(0)]],
                            texture2d<float, access::write> out [[texture(1)]],
                            constant float4& params [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;

            float fx = params.x, fy = params.y, cx = params.z, cy = params.w;
            float k1 = -0.22327126, k2 = 0.04652081, k3 = 0.00112181, k4 = 0.00183698, k5 = -0.00408785;

            float2 p = float2(gid) + 0.5;
            float xn = (p.x - cx) / fx;
            float yn = (p.y - cy) / fy;
            float r = sqrt(xn*xn + yn*yn);

            float2 sp;
            if (r < 0.001) {
                sp = p;
            } else {
                float th = atan(r);
                float th2 = th * th;
                float thd = th * (1.0 + th2*(k1 + th2*(k2 + th2*(k3 + th2*(k4 + th2*k5)))));
                float s = thd / r;
                sp = float2(fx*xn*s + cx, fy*yn*s + cy);
            }

            constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
            out.write(in.sample(s, sp), gid);
        }
        """
        guard let lib = try? dev.makeLibrary(source: src, options: nil),
              let fn = lib.makeFunction(name: "fisheye"),
              let ps = try? dev.makeComputePipelineState(function: fn) else {
            print("❌ Metal compile fail")
            return nil
        }
        self.pipeline = ps
        print("✓ Metal fisheye ready")
    }

    func correct(_ image: CIImage) -> CIImage? {
        // 渲染 CIImage 到 Metal texture
        let w = Int(image.extent.width)
        let h = Int(image.extent.height)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        guard let inTex = device.makeTexture(descriptor: desc),
              let outTex = device.makeTexture(descriptor: desc) else { return nil }

        let ctx = CIContext(mtlDevice: device, options: [.useSoftwareRenderer: false])
        ctx.render(image, to: inTex, commandBuffer: nil, bounds: image.extent, colorSpace: CGColorSpaceCreateDeviceRGB())

        // Metal compute
        guard let cmdBuf = device.makeCommandQueue()?.makeCommandBuffer(),
              let enc = cmdBuf.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(inTex, index: 0)
        enc.setTexture(outTex, index: 1)

        let sx: Float = 932.7 * Float(w) / 2160.0
        let sy: Float = 936.5 * Float(h) / 3840.0
        let scx: Float = 1111.3 * Float(w) / 2160.0
        let scy: Float = 1846.5 * Float(h) / 3840.0
        var p = SIMD4<Float>(sx, sy, scx, scy)
        enc.setBytes(&p, length: 16, index: 0)

        let tg = MTLSize(width: pipeline.threadExecutionWidth, height: pipeline.maxTotalThreadsPerThreadgroup / pipeline.threadExecutionWidth, depth: 1)
        let tgGrid = MTLSize(width: (w + tg.width - 1) / tg.width, height: (h + tg.height - 1) / tg.height, depth: 1)
        enc.dispatchThreadgroups(tgGrid, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return CIImage(mtlTexture: outTex, options: [.colorSpace: CGColorSpaceCreateDeviceRGB() as Any])
    }
}
