//
//  MotionTracker.swift
//  FisheyeGimbal
//
//  CoreMotion 姿态跟踪 + 低通滤波 + 朝向锁定。
//
//  核心思路（和执法记录仪 / 无人机云台增稳同一套）：
//  1. 从 CMDeviceMotion 拿设备姿态四元数 q(t)（世界系，xArbitraryZVertical）。
//  2. 对 q(t) 做低通滤波，把手的抖动滤掉，得到 q_smooth(t)。
//     注意滤波必须做在「旋转」上，直接对欧拉角滤波会在万向节附近炸掉，
//     所以用四元数 slerp：q_smooth = slerp(q_smooth, q_raw, alpha)。
//  3. 锁定的世界朝向 q_lock 固定不变。渲染时的补偿旋转：
//         q_comp = q_lock⁻¹ ⊗ q_smooth
//     这样设备随便晃，画面始终看向开锁那一刻的世界方向。
//  4. 另一个模式是「阻尼」：q_lock 缓慢跟随 q_smooth，晃的时候锁死，
//     慢慢转到新方向时画面跟过去 —— Pocket 3 的"云台跟随"手感。
//
//  陀螺仪有零偏，q_lock 固定不动时会有缓慢漂移，这是物理极限。
//  真云台靠电机+编码器闭环；纯 IMU 只能做到几秒内几乎看不出漂移。
//

import Foundation
import CoreMotion
import simd

/// 渲染线程与运动线程之间共享的快照。用锁保护，不用 @Published（避免线程问题）。
final class MotionState {
    private let lock = NSLock()
    private var stored: MotionSnapshot?

    func update(_ s: MotionSnapshot) {
        lock.lock(); stored = s; lock.unlock()
    }

    func snapshot() -> MotionSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func clear() {
        lock.lock(); stored = nil; lock.unlock()
    }
}

struct MotionSnapshot {
    /// 设备姿态（世界系）
    var attitude = simd_quatf(angle: 0, axis: [0, 1, 0])
    /// 低通滤波后的姿态
    var smooth = simd_quatf(angle: 0, axis: [0, 1, 0])
    /// 锁定朝向
    var locked = simd_quatf(angle: 0, axis: [0, 1, 0])
    /// 补偿旋转 = locked⁻¹ ⊗ smooth，渲染直接用它
    var compensation = simd_quatf(angle: 0, axis: [0, 1, 0])
    var yawCancelling = false
    var yawUnwrapOffset: Float = 0
    var timestamp: Double = 0
}

final class MotionTracker: ObservableObject {

    enum LockMode: String, CaseIterable, Identifiable {
        case hold      // 完全锁死世界方向（真云台锁定模式）
        case damping   // 锁死，但缓慢跟随大范围转向（云台跟随模式）
        var id: String { rawValue }
        var title: String {
            switch self {
            case .hold:    return "锁定"
            case .damping: return "跟随"
            }
        }
    }

    /// 屏幕上显示的实时状态
    @Published private(set) var lockMode: LockMode = .hold
    @Published private(set) var locked = false
    @Published private(set) var available = false
    @Published private(set) var lastError: String?

    /// 平滑时间常数（秒）。越大越稳、但转向越迟钝。
    var smoothing: Double = 0.10 {
        didSet { smoothing = min(max(smoothing, 0.0), 1.5) }
    }
    /// 跟随模式的时间常数（秒）
    var dampingTime: Double = 1.2
    /// 抵消 yaw 漂移（只对"跟随"模式有意义）
    var cancelYaw = false

    let state = MotionState()

    private let motion = CMMotionManager()
    private let motionQueue = OperationQueue()
    private var raw = simd_quatf(angle: 0, axis: [0, 1, 0])
    private var filtered = simd_quatf(angle: 0, axis: [0, 1, 0])
    private var lockQ = simd_quatf(angle: 0, axis: [0, 1, 0])
    private var hasSample = false
    private var lastStamp: Double = 0
    private var yawUnwrap: Float = 0
    private var lockedFlag = false

    // MARK: - 启动 / 停止

    func start() {
        guard motion.isDeviceMotionAvailable else {
            lastError = "设备不支持 DeviceMotion"
            available = false
            return
        }
        available = true
        motion.deviceMotionUpdateInterval = 1.0 / 100.0          // 100 Hz
        // xArbitraryZVertical: z 轴竖直向上，无磁力计修正 -> 无磁干扰、无 yaw 跳变
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical,
                                        to: motionQueue) { [weak self] dm, err in
            guard let self else { return }
            if let err {
                DispatchQueue.main.async { self.lastError = err.localizedDescription }
                return
            }
            guard let dm else { return }
            self.handle(dm)
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }

    // MARK: - 姿态处理

    private func handle(_ dm: CMDeviceMotion) {
        let q = dm.attitude.quaternion
        // CMQuaternion 是 Double；(x,y,z) 是旋转轴分量，w 是标量
        let qRaw = simd_quatf(ix: Float(q.x), iy: Float(q.y), iz: Float(q.z), r: Float(q.w))
        let t = dm.timestamp

        let dt = (lastStamp > 0) ? min(max(t - lastStamp, 1.0 / 240.0), 0.25) : (1.0 / 100.0)
        lastStamp = t

        if !hasSample {
            hasSample = true
            filtered = qRaw
            lockQ = qRaw          // 开锁于当前朝向
        }
        raw = qRaw

        // ---- 四元数低通 ----
        let alpha = smoothing <= 0 ? 1.0 : (1.0 - exp(-dt / smoothing))
        filtered = simd_slerp(filtered, qRaw, Float(min(max(alpha, 0.0), 1.0)))

        // ---- 跟随模式：锁定朝向缓慢追向当前朝向 ----
        if lockMode == .damping {
            let beta = (1.0 - exp(-dt / max(dampingTime, 0.05)))
            lockQ = simd_slerp(lockQ, filtered, Float(min(max(beta, 0.0), 1.0)))
        }

        // ---- yaw 解缠：跨 ±180° 时视图会翻转，这里补回来 ----
        var effectiveLock = lockQ
        if cancelYaw {
            let dYaw = yawDelta(from: lockQ, to: filtered)
            yawUnwrap += dYaw
            effectiveLock = lockQ * simd_quatf(angle: yawUnwrap, axis: [0, 1, 0])
        }

        // q_comp = effectiveLock⁻¹ ⊗ filtered
        let comp = effectiveLock.inverse * filtered

        var s = MotionSnapshot()
        s.attitude = raw
        s.smooth = filtered
        s.locked = effectiveLock
        s.compensation = comp
        s.yawCancelling = cancelYaw
        s.yawUnwrapOffset = yawUnwrap
        s.timestamp = t
        state.update(s)

        // 只在这条状态真的翻转时回主线程，避免 100Hz 塞爆主队列
        if !lockedFlag {
            lockedFlag = true
            DispatchQueue.main.async { self.locked = true }
        }
    }

    /// 两个姿态绕竖直轴(y)的夹角差，解缠到 [-π, π]
    /// 用姿态矩阵的第三列（设备 x 轴方向）的 xz 投影算 yaw，
    /// 绕开四元数双覆盖（q 与 -q 表示同一旋转）的坑。
    private func yawDelta(from a: simd_quatf, to b: simd_quatf) -> Float {
        func yawOf(_ q: simd_quatf) -> Float {
            let m = simd_float3x3(q)
            let xAxis = SIMD3<Float>(m.columns.0.x, 0, m.columns.0.z)
            if simd_length(xAxis) < 1e-5 { return 0 }
            let n = simd_normalize(xAxis)
            return atan2(n.z, n.x)
        }
        var ang = yawOf(b) - yawOf(a)
        while ang > .pi { ang -= 2 * .pi }
        while ang < -.pi { ang += 2 * .pi }
        return ang
    }

    // MARK: - 控制

    /// 重新锁定到当前朝向（相当于云台"回中锁定"）
    func recenter() {
        motionQueue.addOperation { [weak self] in
            guard let self else { return }
            self.lockQ = self.filtered
            self.yawUnwrap = 0
        }
    }

    func setLockMode(_ m: LockMode) {
        lockMode = m
        recenter()
    }
}
