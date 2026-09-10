import AVFoundation
import Foundation

/// The two stimuli under comparison. Only the waveform differs — the HRTF,
/// listener, source position, distance and coordinate system are identical.
public enum Stimulus: String, CaseIterable {
    case original       // Sound A — the Prototype 2 baseline
    case sharp          // Sound B — designed for a compact, well-localised percept
    case hybrid         // Sound C — A's broad low-frequency body + B's sharp highs

    public var displayName: String {
        switch self {
        case .original: return "Original"
        case .sharp:    return "Sharp"
        case .hybrid:   return "Hybrid"
        }
    }
}

/// Which stimulus a session uses.
public enum SoundMode: String, CaseIterable {
    case original
    case sharp
    case hybrid
    case randomAB
    case abc45

    public var title: String {
        switch self {
        case .original: return "Original"
        case .sharp:    return "Sharp"
        case .hybrid:   return "Hybrid"
        case .randomAB: return "Random A/B"
        case .abc45:    return "A/B/C balanced"
        }
    }

    /// Default number of trials for this mode. The UI can override it.
    public var defaultTrialCount: Int { self == .abc45 ? 45 : 30 }

    /// A/B/C needs a multiple of three so the stimuli stay exactly balanced.
    public var trialCountStep: Int { self == .abc45 ? 3 : 1 }

    /// A/B/C uses a pre-built balanced plan rather than a per-trial draw.
    public var usesBalancedPlan: Bool { self == .abc45 }

    /// True for the blinded modes. In these the stimulus is withheld from the
    /// participant UI *and* from the live terminal log, so neither can unblind a
    /// run mid-session.
    public var isBlinded: Bool { self == .randomAB || self == .abc45 }

    /// The stimulus for the next trial. In Random A/B this is an independent
    /// fair coin flip per trial — not a shuffled balanced list, because a
    /// balanced list becomes predictable towards the end of a block.
    public func nextStimulus(rng: inout SplitMix64) -> Stimulus {
        switch self {
        case .original: return .original
        case .sharp:    return .sharp
        case .hybrid:   return .hybrid
        case .randomAB: return rng.nextBool() ? .sharp : .original
        case .abc45:    return .original    // unused: abc45 uses a balanced plan
        }
    }
}

// MARK: - Biquad

/// RBJ cookbook biquad, Direct Form I. Used only to shape Sound B's spectrum;
/// nothing in the spatialisation path touches it.
public struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    public static func lowpass(_ f: Double, q: Double, sr: Double) -> Biquad {
        let w = 2 * .pi * f / sr, a = sin(w) / (2 * q), c = cos(w)
        let a0 = 1 + a
        return normalised(b0: (1 - c) / 2, b1: 1 - c, b2: (1 - c) / 2,
                          a0: a0, a1: -2 * c, a2: 1 - a)
    }

    public static func highpass(_ f: Double, q: Double, sr: Double) -> Biquad {
        let w = 2 * .pi * f / sr, a = sin(w) / (2 * q), c = cos(w)
        let a0 = 1 + a
        return normalised(b0: (1 + c) / 2, b1: -(1 + c), b2: (1 + c) / 2,
                          a0: a0, a1: -2 * c, a2: 1 - a)
    }

    /// Peaking EQ, `gainDB` at centre frequency `f`.
    public static func peaking(_ f: Double, q: Double, gainDB: Double, sr: Double) -> Biquad {
        let A = pow(10, gainDB / 40)
        let w = 2 * .pi * f / sr, a = sin(w) / (2 * q), c = cos(w)
        return normalised(b0: 1 + a * A, b1: -2 * c, b2: 1 - a * A,
                          a0: 1 + a / A, a1: -2 * c, a2: 1 - a / A)
    }

    private static func normalised(b0: Double, b1: Double, b2: Double,
                                   a0: Double, a1: Double, a2: Double) -> Biquad {
        Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// Direct-form coefficients, for the fixed-coefficient loudness filters.
    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    private init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double,
                 x1: Double, x2: Double, y1: Double, y2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
        self.x1 = x1; self.x2 = x2; self.y1 = y1; self.y2 = y2
    }

    public mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }

    /// Filter a buffer twice, keeping state across the two passes, so the output
    /// is very nearly periodic and the looped buffer has no click at the seam.
    public mutating func runCircular(_ x: inout [Double]) {
        for i in 0..<x.count { _ = process(x[i]) }      // prime the state
        for i in 0..<x.count { x[i] = process(x[i]) }
    }
}

// MARK: - Loudness

/// ITU-R BS.1770 K-weighted loudness, used to level-match the two stimuli.
///
/// Equal RMS is NOT equal loudness: Sound B's energy sits where the ear is most
/// sensitive, so matching RMS would leave it audibly louder and confound the
/// comparison with a level difference. K-weighting is the broadcast standard for
/// exactly this problem.
public enum Loudness {

    /// Coefficients are those specified by BS.1770 at 48 kHz, which is the rate
    /// this prototype runs at.
    public static func lufs(_ x: [Float], sampleRate: Double) -> Double {
        precondition(abs(sampleRate - 48_000) < 1, "BS.1770 coefficients assume 48 kHz")
        var shelf = Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
                           a1: -1.69065929318241, a2: 0.73248077421585)
        var rlb = Biquad(b0: 1.0, b1: -2.0, b2: 1.0,
                         a1: -1.99004745483398, a2: 0.99007225036621)
        var sum = 0.0
        for v in x {
            let y = rlb.process(shelf.process(Double(v)))
            sum += y * y
        }
        return -0.691 + 10 * log10(max(sum / Double(x.count), 1e-20))
    }
}

// MARK: - Stimulus generation

public enum StimulusGenerator {

    /// Buffer length. Long enough that the loop is not perceptible.
    public static let durationSeconds = 4.0

    /// Sound A's pre-HRTF RMS. Unchanged from the original prototype.
    public static let originalRMS: Float = 0.10

    // Sound B parameters, all documented in the README.
    // Chosen by measured sweep (see the `diag` tool): this pair minimises
    // envelope periodicity and short-time level variation together, while
    // keeping a crest factor of ~7.7 against white noise's 1.7 — i.e. still
    // strongly transient, but with no audible buzz, rhythm or flutter.
    public static let sharpGrainRateHz = 400.0     // mean grains per second
    public static let sharpGrainMS = 1.5           // Hann-windowed grain length
    public static let sharpHighpassHz = 600.0      // removes the diffuse rumble
    public static let sharpLowpassHz = 10_000.0    // keeps it from being piercing
    public static let sharpPresenceHz = 3_500.0    // HRTF cue band
    public static let sharpPresenceDB = 4.0

    /// Sound A: flat white noise, RMS-normalised. Byte-for-byte the original
    /// Prototype 2 stimulus — same generator, same seed, same level.
    public static func original(sampleRate: Double, seed: UInt64 = 0xC0FFEE) -> [Float] {
        let n = Int(sampleRate * durationSeconds)
        var rng = SplitMix64(seed: seed)
        var out = [Float](repeating: 0, count: n)
        var sumSq = 0.0
        for i in 0..<n {
            let v = Float(rng.nextUniform())
            out[i] = v
            sumSq += Double(v * v)
        }
        let rms = Float((sumSq / Double(n)).squareRoot())
        let gain = originalRMS / max(rms, 1e-9)
        for i in 0..<n { out[i] *= gain }
        return out
    }

    /// Sound B: a dense, irregular train of short band-limited noise bursts.
    ///
    /// Each grain is a 1.5 ms Hann-windowed burst of noise. Grains arrive at a
    /// mean rate of 400/s with +-50% interval jitter, so they fuse into one
    /// continuous texture with no perceptible rhythm, while still presenting the
    /// auditory system with hundreds of sharp onsets per second. The result is
    /// band-limited to 600 Hz - 10 kHz with a small presence lift at 3.5 kHz.
    /// The raw grain train, before any band shaping. Shared by Sound B and the
    /// high layer of Sound C so the two carry the identical temporal structure.
    static func grainTrain(sampleRate: Double, seed: UInt64) -> [Double] {
        let n = Int(sampleRate * durationSeconds)
        var rng = SplitMix64(seed: seed)
        var buf = [Double](repeating: 0, count: n)

        let grainLen = max(2, Int(sharpGrainMS / 1000 * sampleRate))
        // Precompute the Hann window: a smooth envelope keeps each grain a "tick"
        // rather than a spectrally splattered click.
        let window = (0..<grainLen).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(grainLen - 1)) }

        let meanInterval = sampleRate / sharpGrainRateHz
        var pos = 0.0
        while pos < Double(n) {
            let start = Int(pos)
            let amp = 0.7 + 0.3 * (rng.nextUniform() * 0.5 + 0.5)   // mild level jitter
            for k in 0..<grainLen {
                // Wrap around the end of the buffer so the grain train is circular
                // and the loop point carries no gap.
                buf[(start + k) % n] += rng.nextUniform() * window[k] * amp
            }
            // Uniform jitter over +-50% of the mean interval: no periodicity for
            // the ear to latch onto, so no audible buzz or rhythm.
            pos += meanInterval * (0.5 + (rng.nextUniform() * 0.5 + 0.5))
        }
        return buf
    }

    /// Sound B: a dense, irregular train of short band-limited noise bursts.
    ///
    /// Each grain is a 1.5 ms Hann-windowed burst of noise. Grains arrive at a
    /// mean rate of 400/s with +-50% interval jitter, so they fuse into one
    /// continuous texture with no perceptible rhythm, while still presenting the
    /// auditory system with hundreds of sharp onsets per second. The result is
    /// band-limited to 600 Hz - 10 kHz with a small presence lift at 3.5 kHz.
    public static func sharp(sampleRate: Double, seed: UInt64 = 0x5EED_5A1F) -> [Float] {
        var buf = grainTrain(sampleRate: sampleRate, seed: seed)

        // Band-limit. Two cascaded 2nd-order sections per end = 24 dB/octave.
        var hp1 = Biquad.highpass(sharpHighpassHz, q: 0.707, sr: sampleRate)
        var hp2 = Biquad.highpass(sharpHighpassHz, q: 0.707, sr: sampleRate)
        var lp1 = Biquad.lowpass(sharpLowpassHz, q: 0.707, sr: sampleRate)
        var lp2 = Biquad.lowpass(sharpLowpassHz, q: 0.707, sr: sampleRate)
        var pk = Biquad.peaking(sharpPresenceHz, q: 0.9, gainDB: sharpPresenceDB, sr: sampleRate)
        hp1.runCircular(&buf); hp2.runCircular(&buf)
        lp1.runCircular(&buf); lp2.runCircular(&buf)
        pk.runCircular(&buf)

        var out = buf.map { Float($0) }
        // Level-match to Sound A by K-weighted loudness, not by RMS.
        let reference = Loudness.lufs(original(sampleRate: sampleRate), sampleRate: sampleRate)
        let current = Loudness.lufs(out, sampleRate: sampleRate)
        let gain = Float(pow(10, (reference - current) / 20))
        for i in 0..<out.count { out[i] *= gain }
        return out
    }

    // Sound C parameters.
    /// Duplex-theory crossover: below this, azimuth is carried mainly by
    /// fine-structure interaural time difference; above it, by level and
    /// spectral cues. Sound C gives each band to the layer that serves it best.
    public static let hybridCrossoverHz = 1_500.0
    /// Removes the rumble that produces the diffuse, "inside the head" percept
    /// over headphones, while leaving the fine-structure ITD band intact.
    ///
    /// Set to 350 Hz on principle, not by tuning: fine-structure ITD is usable
    /// up to roughly 1.3-1.5 kHz, and the region below ~300 Hz is where the
    /// wavelength so exceeds the head that an HRTF yields almost no level
    /// difference. A 4th-order cut here is ~24 dB down by 175 Hz, so the rumble
    /// goes and everything from ~400 Hz up survives. Chosen before any Hybrid
    /// data existed, and never adjusted against participant results.
    public static let hybridLowCutHz = 350.0

    /// Sound C: a two-layer stimulus split at the duplex-theory crossover.
    ///
    ///   below 1.5 kHz  — Sound A's steady white noise (120 Hz - 1.5 kHz)
    ///   above 1.5 kHz  — Sound B's grain train (1.5 - 10 kHz, +4 dB at 3.5 kHz)
    ///
    /// This is deliberately NOT "both sounds played together". The two layers
    /// occupy complementary bands rather than overlapping at full bandwidth, so
    /// each mechanism operates only where it is physiologically effective: the
    /// steady low band supplies the broad, robust fine-structure ITD that makes
    /// a direction easy to find at all, and the transient high band supplies the
    /// envelope-ITD, level and spectral cues that sharpen the centre.
    ///
    /// The two layers are mixed at EQUAL K-weighted loudness — a neutral choice
    /// fixed in advance, not tuned to any participant's results.
    public static func hybrid(sampleRate: Double, seed: UInt64 = 0x5EED_5A1F) -> [Float] {
        // Low layer: Sound A's noise, band-limited to the ITD region.
        var low = original(sampleRate: sampleRate).map { Double($0) }
        var lhp1 = Biquad.highpass(hybridLowCutHz, q: 0.707, sr: sampleRate)
        var lhp2 = Biquad.highpass(hybridLowCutHz, q: 0.707, sr: sampleRate)
        var llp1 = Biquad.lowpass(hybridCrossoverHz, q: 0.707, sr: sampleRate)
        var llp2 = Biquad.lowpass(hybridCrossoverHz, q: 0.707, sr: sampleRate)
        lhp1.runCircular(&low); lhp2.runCircular(&low)
        llp1.runCircular(&low); llp2.runCircular(&low)

        // High layer: Sound B's grain train, above the crossover.
        var high = grainTrain(sampleRate: sampleRate, seed: seed)
        var hhp1 = Biquad.highpass(hybridCrossoverHz, q: 0.707, sr: sampleRate)
        var hhp2 = Biquad.highpass(hybridCrossoverHz, q: 0.707, sr: sampleRate)
        var hlp1 = Biquad.lowpass(sharpLowpassHz, q: 0.707, sr: sampleRate)
        var hlp2 = Biquad.lowpass(sharpLowpassHz, q: 0.707, sr: sampleRate)
        var hpk = Biquad.peaking(sharpPresenceHz, q: 0.9, gainDB: sharpPresenceDB, sr: sampleRate)
        hhp1.runCircular(&high); hhp2.runCircular(&high)
        hlp1.runCircular(&high); hlp2.runCircular(&high)
        hpk.runCircular(&high)

        // Equal loudness contribution from each layer.
        let lowF = low.map { Float($0) }, highF = high.map { Float($0) }
        let lowL = Loudness.lufs(lowF, sampleRate: sampleRate)
        let highL = Loudness.lufs(highF, sampleRate: sampleRate)
        let balance = pow(10, (lowL - highL) / 20)

        var out = [Float](repeating: 0, count: low.count)
        for i in 0..<out.count { out[i] = Float(low[i] + high[i] * balance) }

        // Then match the whole thing to Sound A, exactly as Sound B is matched.
        let reference = Loudness.lufs(original(sampleRate: sampleRate), sampleRate: sampleRate)
        let current = Loudness.lufs(out, sampleRate: sampleRate)
        let gain = Float(pow(10, (reference - current) / 20))
        for i in 0..<out.count { out[i] *= gain }
        return out
    }

    public static func buffer(_ stimulus: Stimulus, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let samples: [Float]
        switch stimulus {
        case .original: samples = original(sampleRate: format.sampleRate)
        case .sharp:    samples = sharp(sampleRate: format.sampleRate)
        case .hybrid:   samples = hybrid(sampleRate: format.sampleRate)
        }
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        b.frameLength = AVAudioFrameCount(samples.count)
        let p = b.floatChannelData![0]
        for i in 0..<samples.count { p[i] = samples[i] }
        return b
    }
}
