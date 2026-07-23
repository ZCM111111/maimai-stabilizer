import CoreMotion
import Foundation

final class MotionManager: ObservableObject {

    private let lock = NSLock()
    private var _roll: Double = 0, _pitch: Double = 0

    func snapshot() -> (roll: Double, pitch: Double, offsetX: Double, offsetY: Double) {
        lock.lock(); defer { lock.unlock() }
        return (_roll, _pitch, 0, 0)
    }

    private let motion = CMMotionManager()
    private let queue = OperationQueue()
    private var prevRoll: Double = 0, rollAcc: Double = 0
    private var prevPitch: Double = 0, pitchAcc: Double = 0

    func start() {
        guard motion.isDeviceMotionAvailable else { return }
        queue.name = "maimai.motion"; queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        motion.deviceMotionUpdateInterval = 1.0 / 120.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] data, _ in
            guard let self, let d = data else { return }

            // Roll: atan2(gx, -gy) — 水平锁定
            let rawR = atan2(d.gravity.x, -d.gravity.y)
            var rd = rawR - self.prevRoll
            if rd >  .pi { rd -= 2 * .pi }; if rd < -.pi { rd += 2 * .pi }
            self.prevRoll = rawR; self.rollAcc += rd

            // Pitch: atan2(gy, -gz) — 纵向锁定
            let rawP = atan2(d.gravity.y, -d.gravity.z)
            var pd = rawP - self.prevPitch
            if pd >  .pi { pd -= 2 * .pi }; if pd < -.pi { pd += 2 * .pi }
            self.prevPitch = rawP
            if abs(pd) > 0.005 { self.pitchAcc += pd }
            self.pitchAcc *= 0.995  // 缓慢衰减回中

            self.lock.lock()
            self._roll = self.rollAcc
            self._pitch = self.pitchAcc
            self.lock.unlock()
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        lock.lock(); _roll = 0; _pitch = 0; lock.unlock()
        prevRoll = 0; rollAcc = 0; prevPitch = 0; pitchAcc = 0
    }
}
