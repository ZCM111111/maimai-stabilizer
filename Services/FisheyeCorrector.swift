import CoreImage

final class FisheyeCorrector {

    private let kernel: CIKernel

    init?() {
        let src = """
        kernel vec4 fisheye(sampler src) {
            float2 p = samplerCoord(src);
            float2 siz = float2(src.size().x, src.size().y);
            float fx = 932.7 * siz.x / 2160.0;
            float fy = 936.5 * siz.y / 3840.0;
            float cx = 1111.3 * siz.x / 2160.0;
            float cy = 1846.5 * siz.y / 3840.0;
            float k1 = -0.22327126, k2 = 0.04652081, k3 = 0.00112181, k4 = 0.00183698, k5 = -0.00408785;
            float xn = (p.x - cx) / fx;
            float yn = (p.y - cy) / fy;
            float r = sqrt(xn*xn + yn*yn);
            if (r < 0.001) return sample(src, p);
            float th = atan(r);
            float th2 = th * th;
            float thd = th * (1.0 + th2*(k1 + th2*(k2 + th2*(k3 + th2*(k4 + th2*k5)))));
            float s = thd / r;
            float2 sp = float2(fx*xn*s + cx, fy*yn*s + cy);
            return sample(src, sp);
        }
        """
        guard let k = CIKernel(source: src) else {
            print("❌ CIKernel fail")
            return nil
        }
        self.kernel = k
        print("✓ CIKernel ok")
    }

    func correct(_ image: CIImage) -> CIImage? {
        return kernel.apply(extent: image.extent,
                            roiCallback: { _, _ in image.extent },
                            arguments: [image as Any])
    }
}
