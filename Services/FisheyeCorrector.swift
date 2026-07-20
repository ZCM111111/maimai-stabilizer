import CoreImage

/// 用内置 CIBumpDistortion 近似鱼眼矫正（自定义 CIKernel 在项目里编译不通过）
final class FisheyeCorrector {

    func correct(_ image: CIImage) -> CIImage? {
        let w = image.extent.width
        let h = image.extent.height
        let cx = image.extent.midX
        let cy = image.extent.midY
        let r = min(w, h) * 0.55  // 影响范围

        guard let filter = CIFilter(name: "CIBumpDistortion") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: cx, y: cy), forKey: kCIInputCenterKey)
        filter.setValue(Float(r), forKey: kCIInputRadiusKey)
        filter.setValue(-0.3, forKey: kCIInputScaleKey)  // 负值=向外推（去桶形畸变）
        return filter.outputImage
    }
}
