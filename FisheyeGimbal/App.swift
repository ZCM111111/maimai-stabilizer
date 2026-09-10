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

    var body: some Scene {
        WindowGroup {
            ContentView(camera: camera,
                        motion: motion,
                        params: params,
                        orientationTracker: orientationTracker)
                .ignoresSafeArea()
                .statusBarHidden()
                .preferredColorScheme(.dark)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    CameraCapture.requestAccess { ok in
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
