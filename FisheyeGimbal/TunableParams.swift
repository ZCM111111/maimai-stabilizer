//
//  TunableParams.swift
//  FisheyeGimbal
//
//  所有可调参数集中在这里。UI 直接绑，renderer 每帧读。
//  这是标定镜头的操作面板：边看画面边拧，直到直线变直。
//

import SwiftUI
import Combine
import simd

final class TunableParams: ObservableObject {

    /// 参数变化时通知渲染器刷新 uniform
    var onChange: (() -> Void)?

    /// 变化时自动触发（didSet 里调用）
    private func changed() { onChange?() }

    // MARK: - 投影模型

    @Published var projection: DistortionModel.Projection = .equidistant { didSet { changed() } }

    /// 最大半视场角（度）。镜头标称 FOV/2。235° 口径 -> 117.5
    @Published var maxHalfFovDeg: Float = 86 { didSet { changed() } }

    /// 自动推导焦距（f = r_max / θ_max）。关掉就可以手动拧 focalScale。
    @Published var autoFocal: Bool = true { didSet { changed() } }

    /// 手动焦距比例：f = focalScale * (短边/2)
    @Published var focalScale: Float = 0.95 { didSet { changed() } }

    /// 径向修正 r' = r(1 + k1 r² + k2 r⁴)，r 已按半图高归一化
    @Published var k1: Float = 0 { didSet { changed() } }
    @Published var k2: Float = 0 { didSet { changed() } }

    /// 光心偏移（像素）——镜头夹歪了靠这个补
    @Published var centerOffset: CGPoint = .zero { didSet { changed() } }

    /// 成像圈半径（像素）。0 = 自动取短边一半
    @Published var imageCircleRadius: Float = 0 { didSet { changed() } }

    /// 边缘羽化宽度（像素），>0 时把镜头圆边缘渐变掉，避免硬切
    @Published var edgeFeather: Float = 8 { didSet { changed() } }

    // MARK: - 输出

    /// 输出视场角（度），决定画面切多大。越小放大倍率越高、越"正常"
    @Published var outputFovDeg: Float = 75 { didSet { changed() } }

    /// 曝光增益
    @Published var exposure: Float = 1.0 { didSet { changed() } }

    /// 屏幕上方在源帧平面内的方向（由界面方向决定）
    var screenUp: SIMD2<Float> = SIMD2<Float>(0, -1) { didSet { changed() } }

    /// 诊断开关：画同心圆环测试图（验证 shader 是否在跑、输出是否可见）
    @Published var showTestPattern = false { didSet { changed() } }

    /// 诊断开关：跳过姿态补偿，直接取原始鱼眼画面（区分"数学错"还是"姿态错"）
    @Published var poseBypass = false { didSet { changed() } }

    /// 源分辨率（renderer 写入，UI 只读显示）
    @Published var sourceSize: CGSize = .zero
}
