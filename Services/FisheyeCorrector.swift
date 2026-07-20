import CoreImage

/// Debug: 先确认管线是否工作
final class FisheyeCorrector {

    private let testKernel: CIColorKernel?

    init?() {
        let src = """
        kernel vec4 redTint() {
            return vec4(1.0, 0.0, 0.0, 1.0);
        }
        """
        testKernel = CIColorKernel(source: src)
        if testKernel == nil {
            print("❌ CIColorKernel 失败")
            return nil
        }
        print("✓ CIColorKernel 成功")
    }

    func correct(_ image: CIImage) -> CIImage? {
        return testKernel?.apply(extent: image.extent, arguments: [])
    }
}
