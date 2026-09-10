//
//  App.swift
//  FisheyeGimbal
//

import SwiftUI
import AVFoundation

@main
struct FisheyeGimbalApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var params = TunableParams()
    @StateObject private var motion = MotionTracker()
    @StateObject private var camera = CameraCapture()
    @StateObject private var orientationTracker = InterfaceOrientationTracker()
    /// 注册成 StateObject，UI 才会跟着刷新（否则开关点了不生效、发送计数不显示）
    @StateObject private var log = RemoteLog.shared

    var body: some Scene {
        WindowGroup {
            ContentView(camera: camera,
                        motion: motion,
                        params: params,
                        orientationTracker: orientationTracker)
                .environmentObject(log)
                .ignoresSafeArea()
                .statusBarHidden()
                .preferredColorScheme(.dark)
                .onChange(of: camera.diagText) { newValue in
                    // 相机诊断有任何变化就推一次，保证日志有内容
                    if !newValue.isEmpty {
                        RemoteLog.shared.log("CAM-TXT", newValue.replacingOccurrences(of: "\n", with: " / "))
                    }
                }
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    // 开机就自动广播日志，不需要用户配置任何东西
                    RemoteLog.shared.autoStart()
                    RemoteLog.shared.log("APP", "启动 设备=\(UIDevice.current.name) 系统=\(UIDevice.current.systemVersion)")
                    RemoteLog.shared.log("APP", "手机WiFi=\(RemoteLog.localIP) 端口=\(RemoteLog.shared.port) 指定目标=\(RemoteLog.shared.host.isEmpty ? "无(纯广播)" : RemoteLog.shared.host)")
                    CameraCapture.requestAccess { ok in
                        RemoteLog.shared.log("APP", "相机权限=\(ok ? "通过" : "拒绝")")
                        if ok { camera.start(fps: 60) } else { camera.lastError = "摄像头权限被拒绝" }
                    }
                    motion.start()
                }
                .onDisappear {
                    camera.stop()
                    motion.stop()
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        [.portrait, .landscapeLeft, .landscapeRight]
    }
}
