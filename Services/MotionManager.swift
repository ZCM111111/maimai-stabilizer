import CoreMotion
import Foundation

/// 120Hz 陀螺仪处理：连续滚转角 + 平移偏移
final class MotionManager: ObservableObject {

    // MARK: - Thread-safe snapshot for camera pipeline

    private let lock = NSLock()
    private var _snapRoll: Double = 0.0
    private var _snapOffsetX: Double = 0.0
    private var _snapOffsetY: Double = 0.0

    func snapshot() -> (roll: Double, offsetX: Double, offsetY: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (_snapRoll, _snapOffsetX, _snapOffsetY)
    }

    // MARK: - Private state

    private let motion = CMMotionManager()
    private let queue = OperationQueue()

    // Velocity accumulators
    private var velX: Double = 0.0
    private var velY: Double = 0.0

    // Continuous roll tracking
    private var prevRawRoll: Double = 0.0
    private var rollAcc: Double = 0.0

    // MARK: - Tuning

    private let dt: Double = 1.0 / 120.0
    private let velDecay: Double = 0.82       // 速度衰减
    private let posDecay: Double = 0.992      // 位置回中
    private let sensitivity: Double = 0.035   // 加速度→偏移灵敏度
    private let deadZone: Double = 0.02       // 加速度死区

    // MARK: - Lifecycle

    func start() {
        guard motion.isDeviceMotionAvailable else { return }

        queue.name = "maimai.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive

        motion.deviceMotionUpdateInterval = dt
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] data, _ in
            guard let self, let d = data else { return }

            // ── 连续滚转角（无 ±180° 跳变）──
            let raw = atan2(d.gravity.x, -d.gravity.y)
            var delta = raw - self.prevRawRoll
            if delta >  Double.pi { delta -= 2 * Double.pi }
            if delta < -Double.pi { delta += 2 * Double.pi }
            self.prevRawRoll = raw
            self.rollAcc += delta

            // ── 平移偏移 ──
            var ax = d.userAcceleration.x
            var ay = d.userAcceleration.y
            if abs(ax) < self.deadZone { ax = 0 }
            if abs(ay) < self.deadZone { ay = 0 }

            self.velX = (self.velX + ax * self.dt) * self.velDecay
            self.velY = (self.velY + ay * self.dt) * self.velDecay

            var offX = (self._snapOffsetX - self.velX * self.sensitivity) * self.posDecay
            var offY = (self._snapOffsetY - self.velY * self.sensitivity) * self.posDecay
            offX = max(-1, min(1, offX))
            offY = max(-1, min(1, offY))

            // 写入快照
            self.lock.lock()
            self._snapRoll = self.rollAcc
            self._snapOffsetX = offX
            self._snapOffsetY = offY
            self.lock.unlock()
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        lock.lock()
        _snapRoll = 0; _snapOffsetX = 0; _snapOffsetY = 0
        lock.unlock()
        velX = 0; velY = 0
        prevRawRoll = 0; rollAcc = 0
    }
}
