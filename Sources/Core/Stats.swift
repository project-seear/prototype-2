import Foundation

/// Descriptive statistics for one set of trials.
public struct Summary {
    public let label: String
    public let n: Int
    public let meanAbsError: Double
    public let medianAbsError: Double
    public let within5: Double          // percent
    public let within10: Double
    public let within15: Double
    public let meanRT: Double           // ms
    public let medianRT: Double
    public let meanRotation: Double     // degrees
    public let medianRotation: Double
    public let sdAbsError: Double
    public let signedBias: Double       // mean signed error, + = answered left of target
    public let medianSignedError: Double

    public init(label: String, trials: [Trial]) {
        self.label = label
        n = trials.count
        let errs = trials.map { abs($0.finalError) }
        let rts = trials.map { $0.responseTimeMS }
        let rots = trials.map { $0.totalRotation }
        meanAbsError = Stats.mean(errs)
        medianAbsError = Stats.median(errs)
        within5  = Stats.percentWithin(errs, 5)
        within10 = Stats.percentWithin(errs, 10)
        within15 = Stats.percentWithin(errs, 15)
        meanRT = Stats.mean(rts)
        medianRT = Stats.median(rts)
        meanRotation = Stats.mean(rots)
        medianRotation = Stats.median(rots)
        sdAbsError = Stats.sd(errs)
        signedBias = Stats.mean(trials.map { $0.finalError })
        medianSignedError = Stats.median(trials.map { $0.finalError })
    }

    public var report: String {
        guard n > 0 else { return "\(label): no trials\n" }
        return String(format: """
        %@  (n = %d)
          mean |error|      %6.2f deg
          median |error|    %6.2f deg
          sd |error|        %6.2f deg
          within +-5 deg    %5.1f %%
          within +-10 deg   %5.1f %%
          within +-15 deg   %5.1f %%
          mean signed err   %+6.2f deg
          median signed err %+6.2f deg
          mean RT           %6.0f ms
          median RT         %6.0f ms
          mean rotation     %6.1f deg
          median rotation   %6.1f deg

        """, label, n, meanAbsError, medianAbsError, sdAbsError, within5, within10, within15,
             signedBias, medianSignedError, meanRT, medianRT, meanRotation, medianRotation)
    }
}

public enum Stats {

    public static func mean(_ x: [Double]) -> Double {
        x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count)
    }

    public static func median(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    public static func sd(_ x: [Double]) -> Double {
        guard x.count > 1 else { return 0 }
        let m = mean(x)
        return (x.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(x.count - 1)).squareRoot()
    }

    public static func percentWithin(_ errors: [Double], _ limit: Double) -> Double {
        errors.isEmpty ? 0 : 100 * Double(errors.filter { $0 <= limit }.count) / Double(errors.count)
    }

    // MARK: - Tests

    /// Welch's unequal-variance t-test. Returns (t, df, two-sided p).
    public static func welch(_ a: [Double], _ b: [Double]) -> (t: Double, df: Double, p: Double)? {
        guard a.count > 1, b.count > 1 else { return nil }
        let na = Double(a.count), nb = Double(b.count)
        let va = sd(a) * sd(a) / na, vb = sd(b) * sd(b) / nb
        guard va + vb > 0 else { return nil }
        let t = (mean(a) - mean(b)) / (va + vb).squareRoot()
        let df = pow(va + vb, 2) / (va * va / (na - 1) + vb * vb / (nb - 1))
        return (t, df, 2 * studentTTail(abs(t), df))
    }

    /// Mann-Whitney U with a normal approximation and tie correction. Robust to
    /// the skew that angular-error distributions always have.
    public static func mannWhitney(_ a: [Double], _ b: [Double]) -> (u: Double, z: Double, p: Double)? {
        guard a.count > 0, b.count > 0 else { return nil }
        let combined = (a.map { ($0, 0) } + b.map { ($0, 1) }).sorted { $0.0 < $1.0 }
        // Mid-ranks for ties.
        var ranks = [Double](repeating: 0, count: combined.count)
        var i = 0
        var tieTerm = 0.0
        while i < combined.count {
            var j = i
            while j + 1 < combined.count && combined[j + 1].0 == combined[i].0 { j += 1 }
            let r = Double(i + j + 2) / 2
            for k in i...j { ranks[k] = r }
            let t = Double(j - i + 1)
            if t > 1 { tieTerm += t * t * t - t }
            i = j + 1
        }
        var rankSumA = 0.0
        for (idx, item) in combined.enumerated() where item.1 == 0 { rankSumA += ranks[idx] }
        let na = Double(a.count), nb = Double(b.count), n = na + nb
        let u = rankSumA - na * (na + 1) / 2
        let mu = na * nb / 2
        let sigma = (na * nb / 12 * ((n + 1) - tieTerm / (n * (n - 1)))).squareRoot()
        guard sigma > 0 else { return nil }
        let z = (u - mu) / sigma
        return (u, z, 2 * normalTail(abs(z)))
    }

    /// Cohen's d with a pooled SD.
    public static func cohensD(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count > 1, b.count > 1 else { return nil }
        let na = Double(a.count), nb = Double(b.count)
        let pooled = (((na - 1) * pow(sd(a), 2) + (nb - 1) * pow(sd(b), 2)) / (na + nb - 2)).squareRoot()
        guard pooled > 0 else { return nil }
        return (mean(a) - mean(b)) / pooled
    }

    // MARK: - Distributions

    /// Upper-tail probability of the standard normal.
    public static func normalTail(_ z: Double) -> Double {
        0.5 * erfc(z / 2.0.squareRoot())
    }

    /// Upper-tail probability of Student's t, via the regularised incomplete beta.
    public static func studentTTail(_ t: Double, _ df: Double) -> Double {
        let x = df / (df + t * t)
        return 0.5 * incompleteBeta(a: df / 2, b: 0.5, x: x)
    }

    /// Regularised incomplete beta I_x(a,b), continued fraction (Lentz).
    public static func incompleteBeta(a: Double, b: Double, x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let lbeta = lgamma(a + b) - lgamma(a) - lgamma(b)
        let front = exp(lbeta + a * log(x) + b * log(1 - x))
        if x > (a + 1) / (a + b + 2) {
            return 1 - incompleteBeta(a: b, b: a, x: 1 - x)
        }
        var f = 1.0, c = 1.0, d = 0.0
        for i in 0...300 {
            let m = i / 2
            let numerator: Double
            if i == 0 {
                numerator = 1
            } else if i % 2 == 0 {
                let dm = Double(m)
                numerator = (dm * (b - dm) * x) / ((a + 2 * dm - 1) * (a + 2 * dm))
            } else {
                let dm = Double(m)
                numerator = -((a + dm) * (a + b + dm) * x) / ((a + 2 * dm) * (a + 2 * dm + 1))
            }
            d = 1 + numerator * d
            if abs(d) < 1e-30 { d = 1e-30 }
            d = 1 / d
            c = 1 + numerator / c
            if abs(c) < 1e-30 { c = 1e-30 }
            f *= c * d
            if abs(1 - c * d) < 1e-12 { break }
        }
        return front * (f - 1) / a
    }
}

/// Original vs Sharp comparison, used at the end of a Random A/B session.
/// `String(format:)` width flags do not pad `%@` on Darwin, so columns are
/// padded explicitly.
public func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

public func padLeft(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
}

public enum Comparison {

    /// The concise side-by-side table, for any number of stimulus groups.
    public static func table(_ groups: [(String, [Trial])]) -> String {
        let sums = groups.map { Summary(label: $0.0, trials: $0.1) }
        var out = "\n" + String(repeating: "=", count: 22 + 12 * sums.count) + "\n"
        out += "STIMULUS COMPARISON\n"
        out += String(repeating: "=", count: 22 + 12 * sums.count) + "\n\n"
        out += "  " + pad("metric", 20) + sums.map { padLeft($0.label, 12) }.joined() + "\n"
        out += "  " + pad("n", 20) + sums.map { padLeft("\($0.n)", 12) }.joined() + "\n"

        func row(_ name: String, _ f: (Summary) -> Double, _ fmt: String) {
            out += "  " + pad(name, 20)
                 + sums.map { padLeft(String(format: fmt, f($0)), 12) }.joined() + "\n"
        }
        row("mean |error| deg", { $0.meanAbsError }, "%.2f")
        row("median |error| deg", { $0.medianAbsError }, "%.2f")
        row("sd |error| deg", { $0.sdAbsError }, "%.2f")
        row("within +-5 deg %", { $0.within5 }, "%.1f")
        row("within +-10 deg %", { $0.within10 }, "%.1f")
        row("within +-15 deg %", { $0.within15 }, "%.1f")
        row("mean signed deg", { $0.signedBias }, "%+.2f")
        row("median signed deg", { $0.medianSignedError }, "%+.2f")
        row("mean RT ms", { $0.meanRT }, "%.0f")
        row("median RT ms", { $0.medianRT }, "%.0f")
        row("mean rotation deg", { $0.meanRotation }, "%.1f")
        row("median rotation deg", { $0.medianRotation }, "%.1f")

        // Which group leads on each headline metric.
        func best(_ name: String, _ f: (Summary) -> Double, lowerIsBetter: Bool) -> String {
            guard let w = lowerIsBetter ? sums.min(by: { f($0) < f($1) }) : sums.max(by: { f($0) < f($1) })
            else { return "" }
            return "    " + pad(name, 24) + w.label + "\n"
        }
        out += "\n  Best on each metric (descriptive only, not a significance claim):\n"
        out += best("mean |error|", { $0.meanAbsError }, lowerIsBetter: true)
        out += best("median |error|", { $0.medianAbsError }, lowerIsBetter: true)
        out += best("within +-5 deg", { $0.within5 }, lowerIsBetter: false)
        out += best("within +-10 deg", { $0.within10 }, lowerIsBetter: false)
        out += best("within +-15 deg", { $0.within15 }, lowerIsBetter: false)
        out += best("mean RT", { $0.meanRT }, lowerIsBetter: true)
        out += best("mean rotation", { $0.meanRotation }, lowerIsBetter: true)
        return out
    }

    /// Full report: per-group summaries, the table, and every pairwise test.
    public static func report(_ groups: [(String, [Trial])], mode: String) -> String {
        let present = groups.filter { !$0.1.isEmpty }
        guard present.count >= 2 else { return "" }
        var out = table(present)
        out += "\n\n" + String(repeating: "=", count: 66) + "\n"
        out += "PAIRWISE COMPARISONS  (mode: \(mode))\n"
        out += "EXPLORATORY trial-level comparisons from a single session and a\n"
        out += "single participant. p-values are descriptive, not confirmatory.\n"
        out += String(repeating: "=", count: 66) + "\n"
        for i in 0..<present.count {
            for j in (i + 1)..<present.count {
                out += pair(present[j], present[i])   // later group minus earlier
            }
        }
        return out
    }

    /// `a` minus `b` on absolute error.
    public static func pair(_ a: (String, [Trial]), _ b: (String, [Trial])) -> String {
        let ea = a.1.map { abs($0.finalError) }, eb = b.1.map { abs($0.finalError) }
        var out = "\n  \(a.0) vs \(b.0)   (difference is \(a.0) - \(b.0); negative favours \(a.0))\n"
        out += "  " + String(repeating: "-", count: 62) + "\n"
        out += String(format: "  mean difference     %+.2f deg   (%.2f vs %.2f)\n",
                      Stats.mean(ea) - Stats.mean(eb), Stats.mean(ea), Stats.mean(eb))
        out += String(format: "  median difference   %+.2f deg   (%.2f vs %.2f)\n",
                      Stats.median(ea) - Stats.median(eb), Stats.median(ea), Stats.median(eb))
        out += inference(a.1, b.1)
        return out
    }

    /// Inferential statistics, deliberately conservative.
    ///
    /// Every statistic is oriented the same way: `a` minus `b`, matching the
    /// header printed by `pair`. Negative t / negative d means group `a` had the
    /// smaller absolute error; positive Mann-Whitney z means `a` ranked higher
    /// (i.e. worse). Previously Welch was computed b-minus-a while Cohen's d was
    /// a-minus-b, so the two disagreed in sign.
    public static func inference(_ a: [Trial], _ b: [Trial]) -> String {
        let ea = a.map { abs($0.finalError) }
        let eb = b.map { abs($0.finalError) }
        var out = ""

        guard ea.count >= 10, eb.count >= 10 else {
            out += String(format: "  Only %d vs %d trials — too few for any inferential claim.\n", ea.count, eb.count)
            return out
        }

        if let w = Stats.welch(ea, eb) {
            out += String(format: "  Welch t-test        t = %+.3f, df = %.1f, p = %.4f\n", w.t, w.df, w.p)
        }
        if let m = Stats.mannWhitney(ea, eb) {
            out += String(format: "  Mann-Whitney U      U = %.1f, z = %+.3f, p = %.4f\n", m.u, m.z, m.p)
        }
        if let d = Stats.cohensD(ea, eb) {
            let mag = abs(d) < 0.2 ? "negligible" : abs(d) < 0.5 ? "small" : abs(d) < 0.8 ? "medium" : "large"
            out += String(format: "  Cohen's d           %+.3f  (", d) + mag + ")\n"
        }

        return out
    }
}


/// The caveat printed once at the end of every multi-stimulus session.
public let singleSessionCaveat = """

  LIMITATIONS
  -----------
  * One participant, one session. Practice, fatigue, headphone-fit drift and
    attention all vary across a block and none are controlled here.
  * Trials are not paired: each has its own random target angle, so there is no
    matched pair to difference. The tests above are the correct UNPAIRED
    trial-level comparison. The genuine within-subject paired analysis works on
    one mean per participant per condition and needs several participants.
  * 15 trials per stimulus is a small sample. Only a large effect could show
    here, and an apparent difference may easily be noise.
  * Three stimuli means three pairwise tests; no multiple-comparison correction
    is applied, so treat individual p-values with extra caution.
  * The purpose is to decide whether a design is worth testing on more
    participants — not to declare a winner.

"""
