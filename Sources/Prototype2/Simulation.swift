import Core
import Foundation

/// Development-only virtual participant, enabled with `--simulate`.
///
/// This exists to exercise the trial loop, the geometry, the timing and the CSV
/// logging without hardware. It is NEVER used for real data: the app prints a
/// loud banner, the UI shows SIMULATED, and the `tracking_active` column in the
/// CSV is 0 for every simulated trial.
final class HeadSimulator {

    /// The virtual head's true direction, positive = right, in the world frame.
    private(set) var trueYaw: Double = 0
    private var aim: Double = 0

    /// An arbitrary non-zero device-frame origin, so the code has to cope with a
    /// neutral reference that is nowhere near zero.
    private let originOffset: Double = 137.0

    /// CoreMotion reports AirPods yaw positive to the LEFT, so the simulator
    /// inverts too — that way calibration's sign detection is genuinely tested.
    var rawYaw: Double { originOffset - trueYaw }

    /// Where the virtual participant thinks the sound is, once settled.
    private(set) var settleTarget: Double = 0
    private var rng = SplitMix64(seed: 7)

    /// Direct placement, used only by the deterministic geometry test.
    func set(trueYaw: Double) {
        self.trueYaw = trueYaw
        self.aim = trueYaw
    }

    func aim(at yaw: Double) {
        self.aim = yaw
        settleTarget = yaw
    }

    /// First-order approach plus a little jitter, so smoothing and the
    /// total-rotation accumulator see realistic data.
    func step(dt: Double) {
        trueYaw += (aim - trueYaw) * (1 - exp(-dt / 0.45))
        trueYaw += rng.nextUniform() * 0.15
    }

    var isSettled: Bool { abs(trueYaw - aim) < 1.5 }

    /// A plausible human pointing error for the virtual participant.
    func nextBias() -> Double { rng.nextUniform() * 8 }
}
