import Core
import Foundation

/// Accumulates everything recorded during one trial.
final class TrialRecorder {
    let index: Int
    let target: Double
    let stimulus: Stimulus
    let rngSeed: UInt64
    let startTime: Double           // CACurrentMediaTime seconds
    let startDate: Date
    /// Device yaw (already in "positive = right" form) treated as this trial's
    /// forward reference. Re-zeroed every trial so gyro drift cannot accumulate.
    let neutralYaw: Double

    private(set) var samples: [YawSample] = []
    private(set) var totalRotation: Double = 0
    private(set) var currentYaw: Double = 0
    private var lastYaw: Double?

    init(index: Int, target: Double, stimulus: Stimulus, rngSeed: UInt64,
         neutralYaw: Double, startTime: Double) {
        self.index = index
        self.target = target
        self.stimulus = stimulus
        self.rngSeed = rngSeed
        self.neutralYaw = neutralYaw
        self.startTime = startTime
        self.startDate = Date()
    }

    /// `deviceYaw` is HeadTracker.yawRight; `timestamp` shares CACurrentMediaTime's base.
    func add(deviceYaw: Double, timestamp: Double) {
        let yaw = deviceYaw - neutralYaw
        if let last = lastYaw { totalRotation += abs(yaw - last) }
        lastYaw = yaw
        currentYaw = yaw
        samples.append(YawSample(tMS: (timestamp - startTime) * 1000,
                                 yaw: yaw,
                                 rawYaw: deviceYaw,
                                 relativeAngle: Geo.relativeAngle(worldTarget: target, headYaw: yaw)))
    }

    func finish(at responseTime: Double, trackingActive: Bool) -> Trial {
        Trial(index: index,
              targetAngle: target,
              initialHeadYaw: samples.first?.yaw ?? 0,
              neutralDeviceYaw: neutralYaw,
              finalHeadYaw: currentYaw,
              finalError: Geo.delta(target, currentYaw),
              totalRotation: totalRotation,
              responseTimeMS: (responseTime - startTime) * 1000,
              startTimestamp: startDate,
              responseTimestamp: Date(),
              samples: samples.count,
              trackingActive: trackingActive,
              stimulus: stimulus,
              rngSeed: rngSeed)
    }
}
