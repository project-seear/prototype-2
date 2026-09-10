import Core
import CoreMotion
import Foundation
import QuartzCore

/// Head orientation from AirPods (Pro 2 / Pro / Max / 3rd-gen) via CoreMotion's
/// CMHeadphoneMotionManager, which is available on macOS 14+.
///
/// Only yaw is used. Pitch and roll are read for diagnostics and then ignored.
///
/// AirPods have no magnetometer, so yaw is gyro-derived and drifts slowly (a few
/// degrees per minute). The experiment therefore re-zeroes the neutral heading at
/// the start of every trial, which makes drift within one trial negligible.
final class HeadTracker: NSObject, CMHeadphoneMotionManagerDelegate {

    enum Status: Equatable {
        case unsupported            // no CMHeadphoneMotionManager support on this Mac
        case denied                 // user refused motion access
        case notDetermined
        case noDevice               // permitted, but no motion-capable headphones connected
        case active
        case stalled(Double)        // seconds since the last sample

        var isUsable: Bool { self == .active }

        var label: String {
            switch self {
            case .unsupported:   return "UNAVAILABLE (no headphone motion support)"
            case .denied:        return "DENIED (grant Motion & Fitness access)"
            case .notDetermined: return "WAITING for motion permission"
            case .noDevice:      return "INACTIVE (connect AirPods and wear them)"
            case .active:        return "ACTIVE"
            case .stalled(let s): return String(format: "STALLED (%.1fs since last sample)", s)
            }
        }
    }

    private let manager = CMHeadphoneMotionManager()

    /// Continuously unwrapped device yaw in degrees. Not zeroed to anything; the
    /// experiment subtracts its own neutral reference from this.
    private(set) var rawYaw: Double = 0
    private(set) var pitch: Double = 0
    private(set) var roll: Double = 0
    private(set) var lastSampleTime: Double = 0
    private(set) var sampleCount: Int = 0
    private(set) var connected = false

    /// +1 or -1, mapping CMAttitude yaw onto "positive = head turned right".
    /// The default is the expected value for AirPods (attitude yaw is positive
    /// counter-clockwise about the up axis, i.e. positive to the left), but
    /// calibration measures it and overwrites this rather than trusting it.
    var yawSign: Double = -1

    /// Device yaw expressed in the experiment's convention: positive = right.
    var yawRight: Double { yawSign * rawYaw }

    /// Called on the main queue for every motion sample.
    var onSample: ((_ yawRight: Double, _ timestamp: Double) -> Void)?

    var status: Status {
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .denied: return .denied
        case .restricted: return .unsupported
        // notDetermined only matters until the first sample arrives; CoreMotion
        // reports it right up to the moment the user answers the prompt.
        case .notDetermined: if sampleCount == 0 { return .notDetermined }
        default: break
        }
        if sampleCount == 0 { return .noDevice }
        let age = CACurrentMediaTime() - lastSampleTime
        return age > 0.5 ? .stalled(age) : .active
    }

    private var retryTimer: Timer?

    func start() {
        manager.delegate = self
        manager.startConnectionStatusUpdates()
        tryStartUpdates()
        // AirPods are often connected after the app is already running, and
        // isDeviceMotionAvailable is false until then, so keep retrying instead
        // of giving up on the first attempt.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tryStartUpdates()
        }
    }

    private func tryStartUpdates() {
        guard !manager.isDeviceMotionActive, manager.isDeviceMotionAvailable else { return }
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self else { return }
            if let error { self.lastError = error.localizedDescription }
            guard let motion else { return }
            self.ingest(motion)
        }
    }

    func stop() {
        retryTimer?.invalidate()
        manager.stopDeviceMotionUpdates()
        manager.stopConnectionStatusUpdates()
    }

    private(set) var lastError: String?

    private func ingest(_ motion: CMDeviceMotion) {
        let a = motion.attitude
        let degrees = a.yaw * 180 / .pi
        // Keep yaw continuous across the +-180 wrap so head rotation accumulates.
        rawYaw = sampleCount == 0 ? degrees : Geo.unwrap(degrees, previous: rawYaw)
        pitch = a.pitch * 180 / .pi
        roll = a.roll * 180 / .pi
        lastSampleTime = CACurrentMediaTime()
        sampleCount += 1
        onSample?(yawRight, motion.timestamp)
    }

    // MARK: - CMHeadphoneMotionManagerDelegate

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        connected = true
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        connected = false
    }

    var diagnosticsReport: String {
        """
        motion available   : \(manager.isDeviceMotionAvailable)
        motion active      : \(manager.isDeviceMotionActive)
        authorization      : \(HeadTracker.authName(CMHeadphoneMotionManager.authorizationStatus()))
        headphones         : \(connected ? "connected" : "not reported connected")
        samples received   : \(sampleCount)
        raw yaw / pitch / roll : \(fmt(rawYaw)) / \(fmt(pitch)) / \(fmt(roll)) deg
        yaw sign (right +) : \(yawSign > 0 ? "+1" : "-1")
        status             : \(status.label)
        last error         : \(lastError ?? "none")
        """
    }

    private func fmt(_ v: Double) -> String { String(format: "%+.1f", v) }

    static func authName(_ s: CMAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }
}
