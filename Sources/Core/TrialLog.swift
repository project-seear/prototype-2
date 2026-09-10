import Foundation

/// One completed trial.
public struct Trial {
    public var index: Int                 // 1-based trial number
    public var targetAngle: Double        // world-space azimuth of the source, deg
    public var initialHeadYaw: Double     // head yaw at trial start, deg (0 by construction)
    public var neutralDeviceYaw: Double   // uncalibrated device yaw used as this trial's forward reference
    public var finalHeadYaw: Double       // head yaw when SPACE was pressed, deg
    public var finalError: Double         // wrapped(target - finalHeadYaw), deg; + = source still to the right
    public var totalRotation: Double      // summed absolute yaw change over the trial, deg
    public var responseTimeMS: Double
    public var startTimestamp: Date
    public var responseTimestamp: Date
    public var samples: Int
    public var trackingActive: Bool
    public var stimulus: Stimulus
    public var rngSeed: UInt64

    public init(index: Int, targetAngle: Double, initialHeadYaw: Double, neutralDeviceYaw: Double, finalHeadYaw: Double,
                finalError: Double, totalRotation: Double, responseTimeMS: Double,
                startTimestamp: Date, responseTimestamp: Date, samples: Int, trackingActive: Bool,
                stimulus: Stimulus, rngSeed: UInt64) {
        self.index = index; self.targetAngle = targetAngle
        self.initialHeadYaw = initialHeadYaw; self.neutralDeviceYaw = neutralDeviceYaw
        self.finalHeadYaw = finalHeadYaw
        self.finalError = finalError; self.totalRotation = totalRotation
        self.responseTimeMS = responseTimeMS; self.startTimestamp = startTimestamp
        self.responseTimestamp = responseTimestamp; self.samples = samples
        self.trackingActive = trackingActive
        self.stimulus = stimulus; self.rngSeed = rngSeed
    }
}

/// One head-orientation sample inside a trial.
public struct YawSample {
    public var tMS: Double          // ms since trial start
    public var yaw: Double          // head yaw relative to the trial's neutral, deg
    public var rawYaw: Double       // uncalibrated device yaw, deg
    public var relativeAngle: Double // source azimuth in head coordinates, deg
    public init(tMS: Double, yaw: Double, rawYaw: Double, relativeAngle: Double) {
        self.tMS = tMS; self.yaw = yaw; self.rawYaw = rawYaw; self.relativeAngle = relativeAngle
    }
}

/// Writes two CSVs side by side and flushes after every trial, so a crash or an
/// abandoned session still leaves usable data on disk.
public final class TrialLog {

    public let trialsURL: URL
    public let trajectoryURL: URL
    public let directory: URL

    private let trials: FileHandle
    private let trajectory: FileHandle

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(directory: URL, sessionID: String) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        trialsURL = directory.appendingPathComponent("trials_\(sessionID).csv")
        trajectoryURL = directory.appendingPathComponent("trajectory_\(sessionID).csv")

        let trialHeader = "trial,target_angle_deg,initial_head_yaw_deg,neutral_device_yaw_deg,final_head_yaw_deg," +
            "final_error_deg,abs_error_deg,total_rotation_deg,response_time_ms," +
            "trial_start_iso,trial_response_iso,samples,tracking_active,stimulus,rng_seed\n"
        let trajHeader = "trial,t_ms,head_yaw_deg,raw_device_yaw_deg,relative_sound_angle_deg\n"

        FileManager.default.createFile(atPath: trialsURL.path, contents: trialHeader.data(using: .utf8))
        FileManager.default.createFile(atPath: trajectoryURL.path, contents: trajHeader.data(using: .utf8))
        trials = try FileHandle(forWritingTo: trialsURL)
        trajectory = try FileHandle(forWritingTo: trajectoryURL)
        trials.seekToEndOfFile()
        trajectory.seekToEndOfFile()
    }

    public func write(_ t: Trial, samples: [YawSample]) {
        let row = [
            "\(t.index)", f(t.targetAngle), f(t.initialHeadYaw), f(t.neutralDeviceYaw), f(t.finalHeadYaw),
            f(t.finalError), f(abs(t.finalError)), f(t.totalRotation), f(t.responseTimeMS),
            TrialLog.iso.string(from: t.startTimestamp), TrialLog.iso.string(from: t.responseTimestamp),
            "\(t.samples)", t.trackingActive ? "1" : "0", t.stimulus.rawValue, "\(t.rngSeed)",
        ].joined(separator: ",") + "\n"
        trials.write(row.data(using: .utf8)!)

        var body = ""
        for s in samples {
            body += "\(t.index),\(f(s.tMS)),\(f(s.yaw)),\(f(s.rawYaw)),\(f(s.relativeAngle))\n"
        }
        if !body.isEmpty { trajectory.write(body.data(using: .utf8)!) }

        try? trials.synchronize()
        try? trajectory.synchronize()
    }

    public func close() {
        try? trials.close()
        try? trajectory.close()
    }

    private func f(_ v: Double) -> String { String(format: "%.3f", v) }
}
