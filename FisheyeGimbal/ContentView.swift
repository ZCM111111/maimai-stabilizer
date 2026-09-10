//
//  ContentView.swift
//  FisheyeGimbal
//

import SwiftUI
import UIKit
import MetalKit
import simd

struct ContentView: View {

    @ObservedObject var camera: CameraCapture
    @ObservedObject var motion: MotionTracker
    @ObservedObject var params: TunableParams
    @ObservedObject var orientationTracker: InterfaceOrientationTracker

    @StateObject private var container: RendererContainer
    @State private var showPanel = true
    @State private var showAdvanced = false

    init(camera: CameraCapture,
         motion: MotionTracker,
         params: TunableParams,
         orientationTracker: InterfaceOrientationTracker) {
        self.camera = camera
        self.motion = motion
        self.params = params
        self.orientationTracker = orientationTracker
        _container = StateObject(wrappedValue: RendererContainer(params: params, motion: motion))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if container.failed {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("Metal 初始化失败").font(.headline)
                    Text("检查设备是否支持 Metal，或 shader 编译是否出错。")
                        .font(.footnote).multilineTextAlignment(.center).padding(.horizontal, 32)
                }
                .foregroundStyle(.white)
            } else {
                MetalPreviewContainer(container: container,
                                      orientation: orientationTracker.orientation)
                    .ignoresSafeArea()
                    .onPinchToZoom { factor in
                        let next = params.outputFovDeg / Float(factor)
                        params.outputFovDeg = min(max(next, 20), 160)
                    }
            }

            VStack {
                topBar
                Spacer()
                bottomBar
            }

            if showPanel {
                HStack {
                    Spacer()
                    ControlPanel(params: params, motion: motion, camera: camera,
                                 showAdvanced: $showAdvanced)
                        .frame(width: 290)
                        .padding(.trailing, 8)
                        .padding(.vertical, 70)
                }
            }

            if let err = camera.lastError {
                VStack {
                    Spacer()
                    Text(err)
                        .font(.footnote)
                        .padding(10)
                        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                        .padding(.bottom, 80)
                }
            }

            // 诊断浮层：把相机 + 渲染器两块状态都放这，大字直读
            if !camera.diagText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("诊断").font(.caption).bold()
                        Spacer()
                        Button { camera.diagText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                    Text("渲染: " + (container.renderer?.hudText ?? "渲染器未初始化"))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                    Divider().overlay(Color.green.opacity(0.4))
                    Text(camera.diagText)
                        .font(.system(size: 11, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color.green)
                .padding(10)
                .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 340, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.top, 96)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear {
            params.screenUp = orientationTracker.orientation.feScreenUp
            container.attachCamera(camera)
            container.start()
        }
        .onChange(of: orientationTracker.orientation) { newValue in
            params.screenUp = newValue.feScreenUp
            container.redraw()
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Label(motion.locked ? "已锁定" : "等待 IMU",
                  systemImage: motion.locked ? "lock.fill" : "lock.open")
            Text(container.renderer?.hudText ?? "初始化中")
                .monospacedDigit()
            Spacer()
            Button { motion.recenter() } label: {
                Label("回中", systemImage: "scope")
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showPanel.toggle() }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
        }
        .font(.caption2)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.45), in: Capsule())
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Picker("模式", selection: Binding(
                get: { motion.lockMode },
                set: { motion.setLockMode($0) })) {
                ForEach(MotionTracker.LockMode.allCases) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)

            Text(String(format: "横向 %.0f°", params.outputFovDeg))
                .font(.caption2).monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.8))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.45), in: Capsule())
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

// MARK: - 控制面板

struct ControlPanel: View {

    @ObservedObject var params: TunableParams
    @ObservedObject var motion: MotionTracker
    @ObservedObject var camera: CameraCapture
    @Binding var showAdvanced: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {

                HStack {
                    Text("镜头标定").font(.headline)
                    Spacer()
                    Text(camera.sourceSize == .zero ? "-" :
                            "\(Int(camera.sourceSize.width))×\(Int(camera.sourceSize.height))")
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(Color.secondary)
                }

                slider("输出视场角", value: $params.outputFovDeg, range: 20...160, unit: "°")
                slider("镜头半视场角", value: $params.maxHalfFovDeg, range: 30...120, unit: "°")

                Picker("投影模型", selection: $params.projection) {
                    ForEach(DistortionModel.Projection.allCases) { p in
                        Text(p.title).tag(p)
                    }
                }
                .pickerStyle(.menu)

                Toggle("自动推导焦距", isOn: $params.autoFocal).font(.caption)
                if !params.autoFocal {
                    slider("焦距比例", value: $params.focalScale, range: 0.2...2.5, unit: "×")
                }

                Divider()

                Text("畸变修正").font(.caption).bold()
                Text("对着一条直线（门框/桌沿）拧，直到它在画面里变直。")
                    .font(.caption2).foregroundStyle(Color.secondary)
                slider("k1", value: $params.k1, range: -0.5...0.5, unit: "")
                slider("k2", value: $params.k2, range: -0.3...0.3, unit: "")
                slider("光心 X", value: Binding(
                    get: { Float(params.centerOffset.x) },
                    set: { params.centerOffset = CGPoint(x: CGFloat($0), y: params.centerOffset.y) }),
                       range: -200...200, unit: "px")
                slider("光心 Y", value: Binding(
                    get: { Float(params.centerOffset.y) },
                    set: { params.centerOffset = CGPoint(x: params.centerOffset.x, y: CGFloat($0)) }),
                       range: -200...200, unit: "px")

                Divider()

                Text("增稳").font(.caption).bold()
                slider("平滑时间常数", value: Binding(
                    get: { Float(motion.smoothing) },
                    set: { motion.smoothing = Double($0) }),
                       range: 0...0.6, unit: "s")
                Toggle("抵消 Yaw 漂移", isOn: Binding(
                    get: { motion.cancelYaw },
                    set: { motion.cancelYaw = $0 })).font(.caption)

                DisclosureGroup("高级", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        slider("成像圈半径", value: $params.imageCircleRadius, range: 0...1400, unit: "px")
                        slider("边缘羽化", value: $params.edgeFeather, range: 0...80, unit: "px")
                        slider("曝光", value: $params.exposure, range: 0.3...3.0, unit: "×")
                        Picker("帧率", selection: Binding(
                            get: { camera.running ? 60 : 30 },
                            set: { camera.switchFPS($0) })) {
                            Text("30").tag(30)
                            Text("60").tag(60)
                        }
                        .pickerStyle(.segmented)
                        Picker("夹在哪个镜头", selection: Binding(
                            get: { camera.backCamera },
                            set: { camera.selectBackCamera($0) })) {
                            ForEach(CameraCapture.BackCamera.allCases) { c in
                                Text(c.title).tag(c)
                            }
                        }
                        .pickerStyle(.segmented)

                        Divider()
                        Text("诊断").font(.caption2).bold()
                        Picker("显示模式", selection: $params.displayMode) {
                            Text("0 正常去畸变").tag(0)
                            Text("1 同心环测试图").tag(1)
                            Text("2 直接采样源纹理").tag(2)
                            Text("3 UV 坐标着色").tag(3)
                            Text("4 中心红点").tag(4)
                        }
                        .pickerStyle(.menu)
                        .font(.caption2)
                        Toggle("跳过姿态补偿", isOn: $params.poseBypass)
                            .font(.caption2)

                        Divider()
                        Text("实时日志（推到电脑）").font(.caption2).bold()
                        Toggle("开启", isOn: Binding(
                            get: { RemoteLog.shared.enabled },
                            set: { RemoteLog.shared.setEnabled($0) }))
                            .font(.caption2)
                        HStack(spacing: 4) {
                            TextField("电脑IP", text: Binding(
                                get: { RemoteLog.shared.host },
                                set: { RemoteLog.shared.host = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                                .keyboardType(.numbersAndPunctuation)
                                .autocorrectionDisabled()
                            TextField("端口", text: Binding(
                                get: { RemoteLog.shared.port },
                                set: { RemoteLog.shared.port = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 54)
                                .keyboardType(.numberPad)
                        }
                        Text("手机IP \(RemoteLog.localIP)")
                            .font(.caption2)
                            .foregroundStyle(Color.green)
                        if RemoteLog.shared.sentLines > 0 {
                            Text("已发送 \(RemoteLog.shared.sentLines) 行")
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                        }
                        if let e = RemoteLog.shared.lastError {
                            Text(e).font(.caption2).foregroundStyle(Color.red)
                        }
                        Text("电脑上跑 listen-log.ps1 接收")
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
            }
            .padding(12)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func slider(_ title: String, value: Binding<Float>,
                        range: ClosedRange<Float>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.caption2)
                Spacer()
                Text(String(format: "%.3f%@", value.wrappedValue, unit))
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(Color.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}

// MARK: - Metal 视图容器

/// 持有一个 MTKView + FrameRenderer，负责把摄像头帧喂进去。
final class RendererContainer: ObservableObject {

    var mtkView: MTKView?
    private(set) var renderer: FrameRenderer?
    @Published var failed = false

    private let params: TunableParams
    private let motion: MotionTracker

    init(params: TunableParams, motion: MotionTracker) {
        self.params = params
        self.motion = motion
    }

    func makeViewIfNeeded() -> UIView {
        if let v = mtkView { return v }

        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.framebufferOnly = true
        view.isPaused = true                       // 由 FrameRenderer 的 CADisplayLink 驱动
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        view.contentMode = .scaleAspectFit
        view.colorPixelFormat = .bgra8Unorm
        view.backgroundColor = .black

        if let r = FrameRenderer(view: view, motion: motion, params: params) {
            renderer = r
        } else {
            failed = true
        }
        mtkView = view
        return view
    }

    func attachCamera(_ camera: CameraCapture) {
        guard let renderer else { return }
        camera.onFrame = { [weak renderer] pb, ts in
            renderer?.enqueue(pb, captureTime: ts)
        }
    }

    func start() {
        renderer?.startDisplayLink()
    }

    func redraw() {
        mtkView?.setNeedsLayout()
        mtkView?.draw()
    }
}

struct MetalPreviewContainer: UIViewRepresentable {

    @ObservedObject var container: RendererContainer
    let orientation: UIInterfaceOrientation

    func makeUIView(context: Context) -> UIView {
        container.makeViewIfNeeded()
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let mtk = uiView as? MTKView else { return }
        let size = mtk.bounds.size
        if size.width > 0, size.height > 0 {
            let scale = mtk.window?.screen.scale ?? 3
            mtk.drawableSize = CGSize(width: size.width * scale, height: size.height * scale)
        }
        mtk.draw()
    }
}

// MARK: - 捏合缩放

extension View {
    func onPinchToZoom(_ action: @escaping (CGFloat) -> Void) -> some View {
        overlay(PinchCatcher(action: action))
    }
}

private struct PinchCatcher: UIViewRepresentable {
    let action: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true
        let g = UIPinchGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handle(_:)))
        v.addGestureRecognizer(g)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: (CGFloat) -> Void
        init(action: @escaping (CGFloat) -> Void) { self.action = action }
        @objc func handle(_ g: UIPinchGestureRecognizer) {
            guard g.state == .changed else { return }
            action(g.scale)
            g.scale = 1
        }
    }
}
