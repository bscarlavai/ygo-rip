import CoreMotion
import Observation

/// Provides device tilt data for gyro-reactive card effects.
/// Calibrates to the user's holding position on start — whatever angle
/// they're holding the phone becomes the "neutral" baseline.
@MainActor @Observable
final class GyroService {
    static let shared = GyroService()

    private(set) var pitch: Double = 0  // forward/back tilt relative to baseline (-1 to 1)
    private(set) var roll: Double = 0   // left/right tilt relative to baseline (-1 to 1)
    private(set) var isAvailable: Bool = false

    private let motionManager = CMMotionManager()
    private let updateInterval: TimeInterval = 1.0 / 30.0

    // Baseline attitude captured on start
    private var baselinePitch: Double = 0
    private var baselineRoll: Double = 0
    private var hasBaseline = false

    private init() {
        isAvailable = motionManager.isDeviceMotionAvailable
    }

    func start() {
        guard isAvailable, !motionManager.isDeviceMotionActive else { return }
        hasBaseline = false
        motionManager.deviceMotionUpdateInterval = updateInterval
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion, let self else { return }
            Task { @MainActor in
                let currentPitch = motion.attitude.pitch
                let currentRoll = motion.attitude.roll

                // Capture the first reading as baseline (how they're holding the phone)
                if !self.hasBaseline {
                    self.baselinePitch = currentPitch
                    self.baselineRoll = currentRoll
                    self.hasBaseline = true
                    return
                }

                // Delta from baseline, normalized to -1...1
                // ~0.5 radians of tilt from baseline = full effect
                let sensitivity = 0.5
                self.pitch = ((currentPitch - self.baselinePitch) / sensitivity).clamped(to: -1...1)
                self.roll = ((currentRoll - self.baselineRoll) / sensitivity).clamped(to: -1...1)
            }
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        pitch = 0
        roll = 0
        hasBaseline = false
    }
}
