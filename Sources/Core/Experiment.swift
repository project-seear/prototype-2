import Foundation

/// One planned trial: a target angle and the stimulus to play there.
public struct PlannedTrial {
    public var angle: Double
    public var stimulus: Stimulus

    public init(angle: Double, stimulus: Stimulus) {
        self.angle = angle; self.stimulus = stimulus
    }
}

/// Trial schedule and the per-trial accumulator.
public enum Experiment {

    public static let trialCount = 30
    public static let minAngle = -90.0
    public static let maxAngle = 90.0

    /// Interval between a response and the automatic start of the next trial.
    /// Long enough that the participant is not still pressing SPACE, short
    /// enough that 30 trials stay brisk.
    public static var interTrialInterval = 1.5

    /// How close to the calibrated neutral the participant must be facing before
    /// the next trial starts.
    public static var centreToleranceDeg = 10.0

    /// The balanced 45-trial A/B/C plan: 15 Original, 15 Sharp, 15 Hybrid.
    ///
    /// The angular range is cut into 15 equal bins and each stimulus gets exactly
    /// one trial in every bin, with the angle drawn uniformly inside it. That
    /// gives all three stimuli the *same* distribution of target angles, so a
    /// difference between them cannot be an artefact of one having drawn easier
    /// angles — which plain independent sampling of 15 trials could easily do.
    /// The 45 trials are then shuffled, so order is fully randomised and the
    /// stimuli are never blocked.
    ///
    /// Everything is drawn from the session's seeded generator, so the whole plan
    /// is reproducible from `rng_seed` alone.
    public static func makeABCPlan(trials: Int = 45, rng: inout SplitMix64) -> [PlannedTrial] {
        let stimuli: [Stimulus] = [.original, .sharp, .hybrid]
        let bins = max(1, trials / stimuli.count)
        let width = (maxAngle - minAngle) / Double(bins)
        var plan: [PlannedTrial] = []
        for b in 0..<bins {
            let lo = minAngle + Double(b) * width
            for s in stimuli {
                plan.append(PlannedTrial(angle: Double.random(in: lo..<(lo + width), using: &rng),
                                         stimulus: s))
            }
        }
        // Shuffle, but reject orders containing a long run of one stimulus. A
        // plain shuffle of 15/15/15 quite readily produces runs of 5-6, and a
        // streak that long invites adaptation to that sound — which would bias
        // both localisation and the comfort rating. Capping the run at 3 keeps
        // the order random while removing that confound.
        for _ in 0..<200 {
            plan.shuffle(using: &rng)
            if longestRun(plan) <= 3 { return plan }
        }
        return plan
    }

    /// Longest streak of identical consecutive stimuli in a plan.
    public static func longestRun(_ plan: [PlannedTrial]) -> Int {
        var best = 0, run = 0
        for i in plan.indices {
            run = (i > 0 && plan[i].stimulus == plan[i - 1].stimulus) ? run + 1 : 1
            best = max(best, run)
        }
        return best
    }

    /// Stratified sample: one angle drawn uniformly from each of `trialCount`
    /// equal bins spanning -90..+90, then shuffled. This gives uniform coverage
    /// of the range without the clustering that plain uniform sampling produces
    /// in only 30 draws.
    public static func makeSchedule(count: Int = trialCount) -> [Double] {
        let width = (maxAngle - minAngle) / Double(count)
        var angles = (0..<count).map { i -> Double in
            let lo = minAngle + Double(i) * width
            return Double.random(in: lo..<(lo + width))
        }
        angles.shuffle()
        return angles
    }
}

