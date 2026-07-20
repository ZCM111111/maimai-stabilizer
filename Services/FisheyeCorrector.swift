import CoreImage

/// CIBumpDistortion 鱼眼矫正（内置滤镜，已验证管线可用）
final class FisheyeCorrector {

    var strength: Float = 0.5  // 负值=去桶形畸变，绝对值越大越强

    func correct(_ image: CIImage) -> CIImage? {
        let w = image.extent.width
        let h = image.extent.height
        let cx = image.extent.midX
        let cy = image.extent.midY
        let r = Float(min(w, h) * 0.5)

        guard let filter = CIFilter(name: "CIBumpDistortion") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: cx, y: cy), forKey: kCIInputCenterKey)
        filter.setValue(NSNumber(value: r), forKey: kCIInputRadiusKey)
        filter.setValue(NSNumber(value: -strength), forKey: kCIInputScaleKey)
        return filter.outputImage
    }
}
