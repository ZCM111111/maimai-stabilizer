//
//  DistortionModel.swift
//  FisheyeGimbal
//
//  鱼眼镜头模型 + 现场标定参数
//
//  采用等距投影(equidistant)，这是绝大多数手机外接鱼眼镜头的实际模型：
//      r = f * θ          θ = 入射光线与光轴夹角，r = 像高(像素)
//  少数"等立体角"镜头(equisolid)：
//      r = 2 f sin(θ/2)
//
//  为什么要同时支持两种：模型选错，画面中心 20° 内看不出差别，
//  但边缘会明显外扩/内缩。选错的那个可以用 k1/k2 拉回来一部分，
//  所以工程上永远给三个旋钮：模型 + k1 + k2。
//

import Foundation
import CoreGraphics

struct DistortionModel {

    enum Projection: Int, CaseIterable, Identifiable {
        case equidistant = 0
        case equisolid = 1

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .equidistant: return "等距 equidistant"
            case .equisolid:   return "等立体角 equisolid"
            }
        }
    }

    // MARK: - 可调参数

    /// 投影模型
    var projection: Projection = .equidistant

    /// 鱼眼焦距 f（像素）。这是最关键的参数。
    /// 与半视场角的关系：f = r_max / θ_max
    var focal: Float = 620

    /// 光心相对图像中心的偏移（像素）。镜头夹歪了、螺丝没拧正，都靠这个补。
    var centerOffset: CGPoint = .zero

    /// 径向修正多项式系数：r' = r (1 + k1 r² + k2 r⁴)
    /// r 用「相对半图高的归一化值」，避免依赖具体分辨率
    var k1: Float = 0
    var k2: Float = 0

    /// 最大半视场角（度）。镜头标称 FOV 的一半。
    var maxHalfFovDeg: Float = 85

    /// 镜头成像圈半径（像素）。<=0 表示自动推导。
    var imageCircleRadius: Float = 0

    /// 边缘羽化宽度（像素）
    var edgeFeather: Float = 6

    /// 输出视场角（度），决定"正常画面"切多大一块出来
    var outputFovDeg: Float = 75

    /// 曝光增益
    var exposure: Float = 1.0

    // MARK: - 预设

    struct Preset: Identifiable {
        let id = UUID()
        let name: String
        let model: DistortionModel
    }

    /// 常见外接鱼眼镜头的粗暴起点。标称 FOV 大多是「对角线」口径。
    static func preset(forDiagonalFov deg: Float, portrait: Bool = true) -> DistortionModel {
        var m = DistortionModel()
        m.maxHalfFovDeg = deg * 0.5
        // 假设成像圈直径约等于源帧短边（多数手机外接鱼眼刚好打满短边附近）
        // focal 会在拿到真实分辨率后由 renderer 重算，这里只给数量级
        _ = portrait
        return m
    }

    /// 拿到真实分辨率后把几何量补全
    mutating func resolveGeometry(sourceSize: CGSize) {
        let w = Float(sourceSize.width)
        let h = Float(sourceSize.height)

        if imageCircleRadius <= 0 {
            imageCircleRadius = min(w, h) * 0.5
        }

        // f = r_max / θ_max  —— 由成像圈半径和标称半视场角反推标称焦距
        // 只在焦距被"自动"模式使用时生效：调用方通过 autoFocal 控制
        _ = w; _ = h
    }

    /// 由「期望成像圈半径 / 半视场角」直接算焦距
    static func focalFromCircle(radius: Float, halfFovDeg: Float) -> Float {
        let t = max(halfFovDeg, 1) * .pi / 180
        return radius / t
    }

    /// 由「对角线视场角 + 图像尺寸」估算焦距（把短边当作成像圈直径的粗略假设）
    static func estimateFocal(sourceSize: CGSize, diagonalFovDeg: Float) -> Float {
        let r = Float(min(sourceSize.width, sourceSize.height)) * 0.5
        return focalFromCircle(radius: r, halfFovDeg: diagonalFovDeg * 0.5)
    }
}
