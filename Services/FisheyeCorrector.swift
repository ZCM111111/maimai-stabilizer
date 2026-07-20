import CoreImage

/// OpenCV 鱼眼模型矫正（标定参数：2160×3840竖屏基准）
final class FisheyeCorrector {

    // 标定值（来自 chessboard_calibrate.py）
    private let calib: (fx: Float, fy: Float, cx: Float, cy: Float) = (932.7, 936.5, 1111.3, 1846.5)
    private let k: (Float, Float, Float, Float, Float) = (-0.22327126, 0.04652081, 0.00112181, 0.00183698, -0.00408785)
    private let calibW: Float = 2160
    private let calibH: Float = 3840

    private let warpKernel: CIKernel
    private var mapX: CIImage? = nil
    private var mapY: CIImage? = nil
    private var mapSize: CGSize = .zero

    init?() {
        let src = """
        #include <CoreImage/CoreImage.h>
        kernel vec4 fisheye(sampler src,
                            float fx, float fy, float cx, float cy,
                            float k1, float k2, float k3, float k4, float k5)
        {
            float2 p = samplerCoord(src);
            float xn = (p.x - cx) / fx;
            float yn = (p.y - cy) / fy;
            float r2 = xn*xn + yn*yn;
            float r = sqrt(r2);
            if (r < 0.0001) return sample(src, p);

            float theta = atan(r);
            float th2 = theta * theta;
            float thd = theta * (1.0 + th2 * (k1 + th2 * (k2 + th2 * (k3 + th2 * (k4 + th2 * k5)))));
            float scale = thd / r;

            float2 sp = float2(fx * xn * scale + cx, fy * yn * scale + cy);
            return sample(src, samplerTransform(src, sp));
        }
        """
        guard let k = CIKernel(source: src) else { return nil }
        self.warpKernel = k
    }

    func correct(_ image: CIImage) -> CIImage? {
        let w = Float(image.extent.width)
        let h = Float(image.extent.height)

        // 缩放到当前图像尺寸
        let sx = w / calibW
        let sy = h / calibH
        let fx = calib.fx * sx
        let fy = calib.fy * sy
        let cx = calib.cx * sx
        let cy = calib.cy * sy

        return warpKernel.apply(extent: image.extent,
                                roiCallback: { _, rect in rect.insetBy(dx: -50, dy: -50) },
                                arguments: [image, fx, fy, cx, cy, k.0, k.1, k.2, k.3, k.4] as [Any])
    }
}
