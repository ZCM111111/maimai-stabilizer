import CoreImage

final class FisheyeCorrector {

    let ready: Bool

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

    private let kernel: CIWarpKernel

    init?() {
        // 先用简单测试 kernel
        let testSrc = """
        #include <CoreImage/CoreImage.h>
        kernel vec2 testShift() {
            return destCoord() + float2(50.0, 50.0);
        }
        """
        // 鱼眼矫正 kernel
        let fisheyeSrc = """
        #include <CoreImage/CoreImage.h>
        kernel vec2 fisheye(float fx, float fy, float cx, float cy,
                            float k1, float k2, float k3, float k4, float k5)
        {
            float2 p = destCoord();
            float xn = (p.x - cx) / fx;
            float yn = (p.y - cy) / fy;
            float r = sqrt(xn*xn + yn*yn);
            if (r < 0.001) return p;
            float theta = atan(r);
            float th2 = theta * theta;
            float thd = theta * (1.0 + th2*(k1 + th2*(k2 + th2*(k3 + th2*(k4 + th2*k5)))));
            float s = thd / r;
            return float2(fx*xn*s + cx, fy*yn*s + cy);
        }
        """
        if let k = CIWarpKernel(source: fisheyeSrc) {
            self.kernel = k
            self.ready = true
            print("✓ Fisheye kernel loaded")
        } else if let k = CIWarpKernel(source: testSrc) {
            self.kernel = k
            self.ready = false
            print("⚠ Fisheye failed, using test shift kernel")
        } else {
            print("❌ All kernels failed")
            return nil
        }
    }

    func correct(_ image: CIImage) -> CIImage? {
        guard ready else {
            // 测试模式：偏移 50px 验证管线是否工作
            return kernel.apply(extent: image.extent,
                                roiCallback: { _, _ in image.extent },
                                image: image, arguments: [])
        }
        let w = Float(image.extent.width)
        let h = Float(image.extent.height)
        let sx = w / calibW
        let sy = h / calibH
        return kernel.apply(extent: image.extent,
                            roiCallback: { _, _ in image.extent },
                            image: image,
                            arguments: [calibFx*sx, calibFy*sy, calibCx*sx, calibCy*sy,
                                        k1, k2, k3, k4, k5] as [Any])
    }
}
