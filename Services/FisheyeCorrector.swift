import CoreImage

final class FisheyeCorrector {

    let ready: Bool
    private let kernel: CIColorKernel

    init?() {
        // 最简单的测试：每个像素从偏右下的位置采样（画面应向左上移动）
        let testSrc = """
        kernel vec4 test(sampler src) {
            float2 p = samplerCoord(src);
            return sample(src, p - float2(0.0, 100.0));
        }
        """
        if let k = CIColorKernel(source: testSrc) {
            self.kernel = k
            self.ready = false
            print("✓ test kernel loaded (100px shift)")
        } else {
            print("❌ kernel failed")
            return nil
        }
    }

    func correct(_ image: CIImage) -> CIImage? {
        // 测试：向上偏移 100px
        return kernel.apply(extent: image.extent, arguments: [image])
    }
}
