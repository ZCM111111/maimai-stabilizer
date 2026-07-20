import CoreImage

final class FisheyeCorrector {
    // Sepia 测试
    init() {}
    func correct(_ image: CIImage) -> CIImage? {
        // 测试：CISepiaTone 验证管线
        let filter = CIFilter(name: "CISepiaTone")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(1.0, forKey: kCIInputIntensityKey)
        return filter.outputImage
    }
}
