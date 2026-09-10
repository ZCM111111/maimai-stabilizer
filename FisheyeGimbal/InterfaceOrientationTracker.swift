//
//  InterfaceOrientationTracker.swift
//  FisheyeGimbal
//
//  跟踪界面方向。设备朝向变了 -> 源帧纹理里"屏幕上方"的轴也要换。
//

import SwiftUI
import Combine

final class InterfaceOrientationTracker: ObservableObject {

    @Published private(set) var orientation: UIInterfaceOrientation = .portrait

    private var cancellables = Set<AnyCancellable>()

    init() {
        refresh()
        NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    func refresh() {
        let scenes = UIApplication.shared.connectedScenes
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else { return }
        if let o = window.windowScene?.interfaceOrientation, o != orientation {
            orientation = o
        }
    }
}
