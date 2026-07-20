import CoreImage

final class FisheyeCorrector {

    private let calibFx: Float = 932.7
    private let calibFy: Float = 936.5
    private let calibCx: Float = 1111.3
    private let calibCy: Float = 1846.5
    private let calibW: Float = 2160
    private let calibH: Float = 3840

    private let k1: Float = -0.22327126
    private let k2: Float =  0.04652081
    private let k3: Float =  0.00112181
    private let k4: Float =  0.00183698
    private let k5: Float = -0.00408785

    private let kernel: CIColorKernel

    init?() {
        let src = """
        kernel vec4 fisheye(sampler src,
                            float fx, float fy, float cx, float cy,
                            float k1, float k2, float k3, float k4, float k5)
        {
            float2 p = samplerCoord(src);
            float xn = (p.x - cx) / fx;
            float yn = (p.y - cy) / fy;
            float r = sqrt(xn*xn + yn*yn);
            if (r < 0.001) return sample(src, p);

            float theta = atan(r);
            float th2 = theta * theta;
            float thd = theta * (1.0 + th2*(k1 + th2*(k2 + th2*(k3 + th2*(k4 + th2*k5)))));
            float s = thd / r;
            float2 sp = float2(fx*xn*s + cx, fy*yn*s + cy);

            return sample(src, sp);
        }
        """
        guard let k = CIColorKernel(source: src) else {
            print("❌ Fisheye kernel compile failed")
            return nil
        }
        self.kernel = k
        print("✓ Fisheye kernel loaded")
    }

    func correct(_ image: CIImage) -> CIImage? {
        let w = Float(image.extent.width)
        let h = Float(image.extent.height)
        let sx = w / calibW
        let sy = h / calibH
        return kernel.apply(extent: image.extent,
                            arguments: [image,
                                        calibFx*sx, calibFy*sy, calibCx*sx, calibCy*sy,
                                        k1, k2, k3, k4, k5] as [Any])
    }
}
