import AVFoundation
import Core
import Foundation

// Measured verification of the geometry and the HRTF renderer.
//
// Nothing here is assumed: every claim about the spatial audio is checked by
// rendering the actual graph offline and measuring the binaural output for
// interaural level difference (ILD) and interaural time difference (ITD).
// Amplitude panning produces ILD but essentially no ITD; a real HRTF produces
// both. Run this before trusting an experimental session.

let sampleRate = 48_000.0
var failures = 0

func check(_ name: String, _ passed: Bool, _ detail: String) {
    print("  " + (passed ? "PASS" : "FAIL") + " " + pad(name, 56) + detail)
    if !passed { failures += 1 }
}

// MARK: - Offline render

struct Binaural {
    var ildDB: Double       // 20log10(rmsL/rmsR); positive = louder in the left ear
    var itdUS: Double       // positive = right ear leads, i.e. source to the right
    var rms: Double
}

/// Render the real audio graph offline for `seconds` with the source at
/// `worldTarget` and the listener yawed by `headYaw`, then measure it.
func render(worldTarget: Double, headYaw: Double, seconds: Double = 1.0,
            algorithm: AVAudio3DMixingRenderingAlgorithm = .HRTFHQ,
            stimulus: Stimulus = .original) -> Binaural {
    let audio = SpatialAudio(sampleRate: sampleRate)
    audio.player.renderingAlgorithm = algorithm
    audio.setWorldTargetAngle(worldTarget)
    audio.setListenerYaw(headYaw)

    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    try! audio.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    try! audio.engine.start()
    audio.play(stimulus)

    let total = AVAudioFrameCount(sampleRate * seconds)
    let out = AVAudioPCMBuffer(pcmFormat: audio.engine.manualRenderingFormat,
                               frameCapacity: audio.engine.manualRenderingMaximumFrameCount)!
    var left = [Float](), right = [Float]()
    left.reserveCapacity(Int(total)); right.reserveCapacity(Int(total))

    while audio.engine.manualRenderingSampleTime < AVAudioFramePosition(total) {
        let remaining = AVAudioFrameCount(AVAudioFramePosition(total) - audio.engine.manualRenderingSampleTime)
        let n = min(out.frameCapacity, remaining)
        let status = try! audio.engine.renderOffline(n, to: out)
        guard status == .success else { break }
        let ch = out.floatChannelData!
        for i in 0..<Int(out.frameLength) { left.append(ch[0][i]); right.append(ch[1][i]) }
    }
    audio.engine.stop()

    // Discard the first 100 ms: HRTF filters and the player have a warm-up.
    let skip = Int(sampleRate * 0.1)
    return measure(Array(left[skip...]), Array(right[skip...]))
}

func rms(_ x: [Float]) -> Double {
    var s = 0.0
    for v in x { s += Double(v) * Double(v) }
    return (s / Double(x.count)).squareRoot()
}

/// One-pole lowpass, used before the cross-correlation so that the ITD estimate
/// comes from the low frequencies where interaural delay is unambiguous.
func lowpass(_ x: [Float], cutoff: Double) -> [Double] {
    let a = exp(-2 * .pi * cutoff / sampleRate)
    var y = [Double](repeating: 0, count: x.count)
    var prev = 0.0
    for i in 0..<x.count {
        prev = (1 - a) * Double(x[i]) + a * prev
        y[i] = prev
    }
    return y
}

func measure(_ l: [Float], _ r: [Float]) -> Binaural {
    let rl = rms(l), rr = rms(r)
    let ild = 20 * log10(max(rl, 1e-12) / max(rr, 1e-12))

    let ll = lowpass(l, cutoff: 1200), rrf = lowpass(r, cutoff: 1200)
    let maxLag = Int(sampleRate * 0.0015)   // +-1.5 ms covers any human ITD
    var bestLag = 0, bestVal = -Double.infinity
    let n = min(ll.count, rrf.count)
    for k in -maxLag...maxLag {
        var s = 0.0
        var i = max(0, -k)
        let end = min(n, n - k)
        while i < end { s += ll[i] * rrf[i + k]; i += 1 }
        if s > bestVal { bestVal = s; bestLag = k }
    }
    // L[i] matches R[i + k]: a positive k means the signal reaches the right ear
    // k samples LATER, i.e. the left ear leads and the source is to the left.
    let itdUS = -Double(bestLag) / sampleRate * 1e6
    return Binaural(ildDB: ild, itdUS: itdUS, rms: (rl + rr) / 2)
}

// MARK: - 1. Pure geometry

print("\n1. GEOMETRY MATH")
check("wrap(190) == -170", abs(Geo.wrap(190) - (-170)) < 1e-9, "\(Geo.wrap(190))")
check("wrap(-190) == 170", abs(Geo.wrap(-190) - 170) < 1e-9, "\(Geo.wrap(-190))")
check("wrap(180) == 180", abs(Geo.wrap(180) - 180) < 1e-9, "\(Geo.wrap(180))")
check("delta(170, -170) == -20", abs(Geo.delta(170, -170) - (-20)) < 1e-9, "\(Geo.delta(170, -170))")
check("delta(-170, 170) == 20", abs(Geo.delta(-170, 170) - 20) < 1e-9, "\(Geo.delta(-170, 170))")
check("unwrap continuity across +-180",
      abs(Geo.unwrap(-175, previous: 175) - 185) < 1e-9, "\(Geo.unwrap(-175, previous: 175))")

// The table from the brief, both signs.
let table: [(Double, Double, Double)] = [
    (60, 0, 60), (60, 30, 30), (60, 60, 0), (60, 90, -30),
    (-60, 0, -60), (-60, -30, -30), (-60, -60, 0), (-60, -90, 30),
    (90, -45, 135), (-90, 45, -135),
]
for (t, h, expected) in table {
    let got = Geo.relativeAngle(worldTarget: t, headYaw: h)
    check("target \(Int(t))deg, head \(Int(h))deg -> \(Int(expected))deg", abs(got - expected) < 1e-9,
          String(format: "%.1f", got))
}

// +X right / -Z forward.
let pRight = Geo.position(azimuth: 90), pFwd = Geo.position(azimuth: 0), pLeft = Geo.position(azimuth: -90)
check("azimuth +90 is +X (right)", pRight.x > 1.0 && abs(pRight.z) < 1e-6, String(format: "(%.2f, %.2f, %.2f)", pRight.x, pRight.y, pRight.z))
check("azimuth 0 is -Z (forward)", pFwd.z < -1.0 && abs(pFwd.x) < 1e-6, String(format: "(%.2f, %.2f, %.2f)", pFwd.x, pFwd.y, pFwd.z))
check("azimuth -90 is -X (left)", pLeft.x < -1.0, String(format: "(%.2f, %.2f, %.2f)", pLeft.x, pLeft.y, pLeft.z))

// MARK: - 2. HRTF is really active

print("\n2. HRTF RENDERER")
let probe = SpatialAudio(sampleRate: sampleRate)
let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
try! probe.engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
try! probe.engine.start()
print("  " + probe.diagnosticsReport.replacingOccurrences(of: "\n", with: "\n  "))
check("HRTFHQ applicable and in force", probe.hrtfActive, SpatialAudio.name(of: probe.player.renderingAlgorithm))
probe.engine.stop()

let hrtfRight = render(worldTarget: 60, headYaw: 0)
let panRight = render(worldTarget: 60, headYaw: 0, algorithm: .equalPowerPanning)
check("HRTF at +60deg produces a real ITD (>200us)", abs(hrtfRight.itdUS) > 200,
      String(format: "%.0f us", hrtfRight.itdUS))
check("amplitude panning at +60deg produces ~no ITD (<60us)", abs(panRight.itdUS) < 60,
      String(format: "%.0f us  (contrast case)", panRight.itdUS))
check("HRTF output is non-silent", hrtfRight.rms > 0.001, String(format: "rms %.4f", hrtfRight.rms))

// MARK: - 3. Static azimuth sweep

print("\n3. STATIC AZIMUTH SWEEP  (head at 0deg, source moved)")
print("     azimuth      ILD dB (L-R)    ITD us (+ = right)")
var staticMeasurements: [Double: Binaural] = [:]
for az in [-90.0, -60, -30, 0, 30, 60, 90] {
    let m = render(worldTarget: az, headYaw: 0)
    staticMeasurements[az] = m
    print(String(format: "     %+6.1f       %+8.2f        %+8.0f", az, m.ildDB, m.itdUS))
}
check("centre (0deg) is balanced in level", abs(staticMeasurements[0]!.ildDB) < 1.5,
      String(format: "%.2f dB", staticMeasurements[0]!.ildDB))
check("centre (0deg) has ~no ITD", abs(staticMeasurements[0]!.itdUS) < 60,
      String(format: "%.0f us", staticMeasurements[0]!.itdUS))
check("+90deg is louder in the RIGHT ear", staticMeasurements[90]!.ildDB < -2,
      String(format: "%.2f dB", staticMeasurements[90]!.ildDB))
check("-90deg is louder in the LEFT ear", staticMeasurements[-90]!.ildDB > 2,
      String(format: "%.2f dB", staticMeasurements[-90]!.ildDB))
// ILD is only monotonic out to roughly +-60deg: head-shadow diffraction makes the
// ILD at +-90deg slightly SMALLER than at +-60deg. That is a genuine property of a
// real HRTF (and a sign this is not amplitude panning, which would be monotonic
// all the way). ITD, by contrast, does grow monotonically across the whole range,
// so that is the global check.
let sweep = [-90.0, -60, -30, 0, 30, 60, 90]
check("ILD decreases monotonically over -60..+60deg",
      zip([-60.0, -30, 0, 30].map { $0 }, [-30.0, 0, 30, 60])
          .allSatisfy { staticMeasurements[$0]!.ildDB > staticMeasurements[$1]!.ildDB + 0.5 },
      "ok")
check("ITD increases monotonically over -90..+90deg",
      zip(sweep.dropLast(), sweep.dropFirst())
          .allSatisfy { staticMeasurements[$0]!.itdUS < staticMeasurements[$1]!.itdUS - 50 },
      "ok")
check("+90deg: right ear leads (positive ITD)", staticMeasurements[90]!.itdUS > 200,
      String(format: "%.0f us", staticMeasurements[90]!.itdUS))
check("-90deg: left ear leads (negative ITD)", staticMeasurements[-90]!.itdUS < -200,
      String(format: "%.0f us", staticMeasurements[-90]!.itdUS))

// MARK: - 4. World-fixed source vs. head rotation

print("\n4. WORLD-FIXED SOURCE, HEAD ROTATED")
print("     the source never moves; only the listener yaws.")
print("     target  head    expected rel   ILD dB     ITD us    static-ref ILD  ITD")
for (target, head, expectedRel) in table.prefix(8) {
    let rotated = render(worldTarget: target, headYaw: head)
    let reference = render(worldTarget: expectedRel, headYaw: 0)
    print(String(format: "     %+6.0f %+6.0f      %+6.0f     %+7.2f  %+8.0f      %+7.2f %+8.0f",
                 target, head, expectedRel, rotated.ildDB, rotated.itdUS, reference.ildDB, reference.itdUS))
    let ildOK = abs(rotated.ildDB - reference.ildDB) < 1.5
    let itdOK = abs(rotated.itdUS - reference.itdUS) < 90
    check("target \(Int(target)) + head \(Int(head)) renders as \(Int(expectedRel))deg",
          ildOK && itdOK,
          String(format: "dILD %.2f dB, dITD %.0f us", rotated.ildDB - reference.ildDB,
                 rotated.itdUS - reference.itdUS))
}

// The critical failure this catches: a sign error in the listener yaw would make
// turning towards the source make it MORE lateral instead of less.
let atTarget = render(worldTarget: 60, headYaw: 60)
check("turning to face the source centres it (ILD -> 0)", abs(atTarget.ildDB) < 1.5,
      String(format: "%.2f dB at target=+60, head=+60", atTarget.ildDB))
check("turning to face the source centres it (ITD -> 0)", abs(atTarget.itdUS) < 60,
      String(format: "%.0f us", atTarget.itdUS))
let overshoot = render(worldTarget: 60, headYaw: 90)
check("overshooting puts the source on the LEFT", overshoot.ildDB > 1,
      String(format: "%.2f dB at target=+60, head=+90 (rel -30)", overshoot.ildDB))


// MARK: - 5. Stimuli

print("\n5. STIMULI  (Sound A = original, Sound B = sharp)")
let audioProbe = SpatialAudio(sampleRate: sampleRate)
let sampleA = audioProbe.samples(of: .original)
let sampleB = audioProbe.samples(of: .sharp)
let sampleC = audioProbe.samples(of: .hybrid)

func rmsF(_ x: [Float]) -> Double { rms(x) }

/// Fraction of total energy a 4th-order band-limited copy retains. The same
/// filters are applied to both stimuli, so the comparison is fair even though
/// the skirts are not brick-wall.
func bandFraction(_ x: [Float], low: Double?, high: Double?) -> Double {
    var y = x.map { Double($0) }
    if let f = low {
        var h1 = Biquad.highpass(f, q: 0.707, sr: sampleRate)
        var h2 = Biquad.highpass(f, q: 0.707, sr: sampleRate)
        h1.runCircular(&y); h2.runCircular(&y)
    }
    if let f = high {
        var l1 = Biquad.lowpass(f, q: 0.707, sr: sampleRate)
        var l2 = Biquad.lowpass(f, q: 0.707, sr: sampleRate)
        l1.runCircular(&y); l2.runCircular(&y)
    }
    let band = (y.map { $0 * $0 }.reduce(0, +) / Double(y.count)).squareRoot()
    return band / max(rmsF(x), 1e-12)
}

let lowA = bandFraction(sampleA, low: nil, high: 300)
let lowB = bandFraction(sampleB, low: nil, high: 300)
let midA = bandFraction(sampleA, low: 2000, high: 8000)
let midB = bandFraction(sampleB, low: 2000, high: 8000)
let lufsA = Loudness.lufs(sampleA, sampleRate: sampleRate)
let lufsB = Loudness.lufs(sampleB, sampleRate: sampleRate)

let lowC = bandFraction(sampleC, low: nil, high: 300)
let midC = bandFraction(sampleC, low: 2000, high: 8000)
let lufsC = Loudness.lufs(sampleC, sampleRate: sampleRate)

func srow(_ name: String, _ a: String, _ b: String, _ c: String) {
    print("     " + pad(name, 24) + padLeft(a, 12) + padLeft(b, 12) + padLeft(c, 12))
}
func srowF(_ name: String, _ fmt: String, _ a: Double, _ b: Double, _ c: Double) {
    srow(name, String(format: fmt, a), String(format: fmt, b), String(format: fmt, c))
}
srow("measure", "original", "sharp", "hybrid")
srowF("RMS", "%.4f", rmsF(sampleA), rmsF(sampleB), rmsF(sampleC))
srowF("peak", "%.4f", Double(audioProbe.peak(of: .original)),
      Double(audioProbe.peak(of: .sharp)), Double(audioProbe.peak(of: .hybrid)))
srowF("loudness LUFS", "%.2f", lufsA, lufsB, lufsC)
srowF("energy below 300 Hz", "%.3f", lowA, lowB, lowC)
srowF("energy 2-8 kHz", "%.3f", midA, midB, midC)

check("Sound A is unchanged: RMS is exactly 0.10", abs(rmsF(sampleA) - 0.10) < 0.002,
      String(format: "%.4f", rmsF(sampleA)))
check("all three stimuli are loudness-matched (<0.5 LU)",
      abs(lufsA - lufsB) < 0.5 && abs(lufsA - lufsC) < 0.5,
      String(format: "sharp %+.2f LU, hybrid %+.2f LU vs original", lufsB - lufsA, lufsC - lufsA))
check("no stimulus clips", Stimulus.allCases.allSatisfy { audioProbe.peak(of: $0) < 0.99 },
      String(format: "peaks %.3f / %.3f / %.3f", Double(audioProbe.peak(of: .original)),
             Double(audioProbe.peak(of: .sharp)), Double(audioProbe.peak(of: .hybrid))))
check("Sharp has less energy below 300 Hz", lowB < lowA * 0.5,
      String(format: "%.3f vs %.3f (%.0f%% less)", lowB, lowA, 100 * (1 - lowB / lowA)))
check("Sharp has more energy in the 2-8 kHz cue band", midB > midA,
      String(format: "%.3f vs %.3f (%+.0f%%)", midB, midA, 100 * (midB / midA - 1)))

/// Envelope autocorrelation: a strongly periodic stimulus would show a large
/// peak at its repetition lag and be heard as a buzz or rhythm.
func envelopePeriodicity(_ x: [Float]) -> Double {
    var env = [Double](repeating: 0, count: x.count)
    var lp = Biquad.lowpass(200, q: 0.707, sr: sampleRate)
    for i in 0..<x.count { env[i] = lp.process(abs(Double(x[i]))) }
    let m = env.reduce(0, +) / Double(env.count)
    for i in 0..<env.count { env[i] -= m }
    let power = env.map { $0 * $0 }.reduce(0, +)
    guard power > 0 else { return 0 }
    var worst = 0.0
    // Start above 1.5x the grain length: within one grain the envelope is
    // correlated with itself simply because a grain has a shape, and a single
    // grain's shape is not a rhythm. Beyond that, out to 50 ms, covers every
    // repetition rate that would be heard as a buzz or a pulse.
    let fromLag = Int(sampleRate * StimulusGenerator.sharpGrainMS * 1.5 / 1000)
    for lag in stride(from: fromLag, to: Int(sampleRate * 0.05), by: 4) {
        var acc = 0.0
        var i = 0
        while i < env.count - lag { acc += env[i] * env[i + lag]; i += 1 }
        worst = max(worst, abs(acc) / power)
    }
    return worst
}
let periodB = envelopePeriodicity(sampleB)
let periodA = envelopePeriodicity(sampleA)
check("Sharp has no periodic buzz or rhythm", periodB < 0.15,
      String(format: "peak envelope autocorrelation %.3f (white noise: %.3f)", periodB, periodA))

/// Peak-to-RMS. White noise sits near 1.7; a stimulus built from distinct
/// onsets sits far higher. This is what "sharp" means physically.
func crest(_ x: [Float]) -> Double {
    var peak = 0.0, sum = 0.0
    for v in x { peak = max(peak, abs(Double(v))); sum += Double(v) * Double(v) }
    return peak / (sum / Double(x.count)).squareRoot()
}
let crestA = crest(sampleA), crestB = crest(sampleB), crestC = crest(sampleC)
check("Sharp is markedly more transient than Original", crestB > crestA * 3,
      String(format: "crest factor %.2f vs %.2f", crestB, crestA))

// --- Sound C must genuinely sit between the two, not duplicate either ---
print("\n     Sound C (Hybrid) — must be intermediate, not a copy of either")
check("Hybrid is more transient than Original", crestC > crestA * 2,
      String(format: "crest %.2f vs %.2f", crestC, crestA))
check("Hybrid is less transient than Sharp (gentler)", crestC < crestB,
      String(format: "crest %.2f vs %.2f", crestC, crestB))
check("Hybrid keeps low-frequency body that Sharp discards", lowC > lowB * 3,
      String(format: "%.3f vs sharp %.3f", lowC, lowB))
check("Hybrid has less sub-300 Hz than Original", lowC < lowA,
      String(format: "%.3f vs original %.3f", lowC, lowA))
check("Hybrid gains high-band cue energy over Original", midC > midA,
      String(format: "%.3f vs original %.3f", midC, midA))
check("Hybrid has no periodic buzz or rhythm", envelopePeriodicity(sampleC) < 0.15,
      String(format: "%.3f", envelopePeriodicity(sampleC)))

// The layers must be complementary, not two full-band copies summed. Below the
// crossover the grain layer should be absent; above it, the noise layer should be.
let lowBandC = bandFraction(sampleC, low: nil, high: 1000)
let lowBandB = bandFraction(sampleB, low: nil, high: 1000)
check("Hybrid is not just A and B summed at full bandwidth",
      lowBandC > lowBandB * 2 && crestC < crestB,
      String(format: "sub-1kHz share %.3f (sharp %.3f), crest %.2f", lowBandC, lowBandB, crestC))

// MARK: - 6. Both stimuli through the same HRTF

print("\n6. HRTF AND WORLD-FIXED GEOMETRY FOR BOTH STIMULI")
for stim in Stimulus.allCases {
    let right = render(worldTarget: 60, headYaw: 0, stimulus: stim)
    let centred = render(worldTarget: 60, headYaw: 60, stimulus: stim)
    let ref30 = render(worldTarget: 30, headYaw: 0, stimulus: stim)
    let rot30 = render(worldTarget: 60, headYaw: 30, stimulus: stim)
    print("     " + pad(stim.rawValue, 10)
          + String(format: "+60deg: ILD %+6.2f dB, ITD %+5.0f us | facing it: ILD %+5.2f dB, ITD %+4.0f us",
                   right.ildDB, right.itdUS, centred.ildDB, centred.itdUS))
    check("\(stim.rawValue): real ITD at +60deg (HRTF active)", abs(right.itdUS) > 200,
          String(format: "%.0f us", right.itdUS))
    check("\(stim.rawValue): lateralises to the right ear", right.ildDB < -2,
          String(format: "%.2f dB", right.ildDB))
    check("\(stim.rawValue): facing the source centres it", abs(centred.ildDB) < 1.5 && abs(centred.itdUS) < 60,
          String(format: "%.2f dB, %.0f us", centred.ildDB, centred.itdUS))
    check("\(stim.rawValue): world-fixed (target+60/head+30 == static +30)",
          abs(rot30.ildDB - ref30.ildDB) < 1.5 && abs(rot30.itdUS - ref30.itdUS) < 90,
          String(format: "dILD %.2f dB, dITD %.0f us", rot30.ildDB - ref30.ildDB, rot30.itdUS - ref30.itdUS))
}

// MARK: - 7. Randomisation

print("\n6a. BALANCED 45-TRIAL A/B/C SCHEDULE")
do {
    var counts: [Stimulus: Int] = [:]
    var worstRun = 0
    var worstAngle = 0.0
    var meanByStim: [Stimulus: [Double]] = [:]
    let sessions = 400
    for k in 0..<sessions {
        var rng = SplitMix64(seed: UInt64(k) &* 0x9E37_79B9_7F4A_7C15 &+ 1)
        let plan = Experiment.makeABCPlan(rng: &rng)
        if plan.count != 45 { check("plan is 45 trials", false, "\(plan.count)"); break }
        var per: [Stimulus: Int] = [:]
        for t in plan {
            per[t.stimulus, default: 0] += 1
            worstAngle = max(worstAngle, abs(t.angle))
            meanByStim[t.stimulus, default: []].append(t.angle)
        }
        for (s, c) in per { counts[s, default: 0] += c == 15 ? 1 : 0 }
        worstRun = max(worstRun, Experiment.longestRun(plan))
    }
    check("every session is exactly 15/15/15",
          Stimulus.allCases.allSatisfy { counts[$0] == sessions }, "\(sessions) sessions")
    check("no target ever leaves +-90deg", worstAngle <= 90.0,
          String(format: "largest |angle| %.2f deg over %d sessions", worstAngle, sessions))
    check("stimuli are never blocked (max run <= 3)", worstRun <= 3,
          "longest run seen: \(worstRun)")
    let means = Stimulus.allCases.map { abs(Stats.mean(meanByStim[$0] ?? [])) }
    check("all three stimuli get the same angular distribution", means.allSatisfy { $0 < 1.0 },
          String(format: "|mean angle| %.2f / %.2f / %.2f deg", means[0], means[1], means[2]))

    // Reproducibility: the same seed must rebuild the identical session.
    var r1 = SplitMix64(seed: 424242), r2 = SplitMix64(seed: 424242)
    let p1 = Experiment.makeABCPlan(rng: &r1), p2 = Experiment.makeABCPlan(rng: &r2)
    let same = zip(p1, p2).allSatisfy { $0.stimulus == $1.stimulus && abs($0.angle - $1.angle) < 1e-12 }
    check("the recorded seed reproduces the session exactly", same, "45/45 trials identical")
}

print("\n7. RANDOM A/B SELECTION")
do {
    var rng = SplitMix64(seed: 0xA1B2_C3D4_E5F6_0718)
    let n = 20_000
    var draws: [Stimulus] = []
    for _ in 0..<n { draws.append(SoundMode.randomAB.nextStimulus(rng: &rng)) }
    let sharpCount = draws.filter { $0 == .sharp }.count
    let proportion = Double(sharpCount) / Double(n)
    check("Random A/B is ~50/50", abs(proportion - 0.5) < 0.02,
          String(format: "%.1f%% sharp over %d draws", proportion * 100, n))

    // Wald-Wolfowitz runs test: a predictable sequence (alternating, or sticky)
    // has far too many or too few runs.
    var runs = 1
    for i in 1..<n where draws[i] != draws[i - 1] { runs += 1 }
    let n1 = Double(sharpCount), n2 = Double(n - sharpCount)
    let expected = 2 * n1 * n2 / Double(n) + 1
    let variance = 2 * n1 * n2 * (2 * n1 * n2 - Double(n)) / (Double(n) * Double(n) * (Double(n) - 1))
    let z = (Double(runs) - expected) / variance.squareRoot()
    check("sequence is unpredictable (runs test)", abs(z) < 2.58,
          String(format: "runs %d, expected %.0f, z %+.2f", runs, expected, z))

    // The fixed modes must never vary.
    var r2 = SplitMix64(seed: 1)
    let allOriginal = (0..<500).allSatisfy { _ in SoundMode.original.nextStimulus(rng: &r2) == .original }
    let allSharp = (0..<500).allSatisfy { _ in SoundMode.sharp.nextStimulus(rng: &r2) == .sharp }
    check("ORIGINAL mode always plays Sound A", allOriginal, "500 draws")
    check("SHARP mode always plays Sound B", allSharp, "500 draws")

    // Different seeds must give different sequences.
    var x = SplitMix64(seed: 11), y = SplitMix64(seed: 12)
    let sx = (0..<60).map { _ in SoundMode.randomAB.nextStimulus(rng: &x) }
    let sy = (0..<60).map { _ in SoundMode.randomAB.nextStimulus(rng: &y) }
    check("different seeds give different sequences", sx != sy, "60-trial sequences differ")
}

// MARK: - 8. Statistics

print("\n8. STATISTICS")
do {
    func fakeTrial(_ err: Double, _ stim: Stimulus) -> Trial {
        Trial(index: 0, targetAngle: 0, initialHeadYaw: 0, neutralDeviceYaw: 0,
              finalHeadYaw: -err, finalError: err, totalRotation: abs(err) * 2,
              responseTimeMS: 1000 + abs(err) * 10, startTimestamp: Date(),
              responseTimestamp: Date(), samples: 10, trackingActive: true,
              stimulus: stim, rngSeed: 0)
    }
    let errs = [1.0, 2, 3, 4, 6, 8, 11, 14, 20, 30]
    let sum = Summary(label: "test", trials: errs.map { fakeTrial($0, .original) })
    check("median of 10 values", abs(sum.medianAbsError - 7.0) < 1e-9, "\(sum.medianAbsError)")
    check("percent within +-5", abs(sum.within5 - 40) < 1e-9, "\(sum.within5)%")
    check("percent within +-10", abs(sum.within10 - 60) < 1e-9, "\(sum.within10)%")
    check("percent within +-15", abs(sum.within15 - 80) < 1e-9, "\(sum.within15)%")
    check("sd of absolute error", abs(sum.sdAbsError - 9.2310) < 0.001, String(format: "%.4f", sum.sdAbsError))
    check("median signed error", abs(sum.medianSignedError - 7.0) < 1e-9, "\(sum.medianSignedError)")

    // Wrapping must survive the whole pipeline: an error either side of +-180.
    let wrapped = Summary(label: "wrap", trials: [fakeTrial(Geo.delta(170, -170), .original)])
    check("angular error still wraps correctly", abs(wrapped.meanAbsError - 20) < 1e-9,
          String(format: "%.1f deg", wrapped.meanAbsError))

    // Known reference values for the test statistics.
    let g1 = [1.0, 2, 3, 4, 5], g2 = [6.0, 7, 8, 9, 10]
    if let w = Stats.welch(g1, g2) {
        check("Welch t on a known pair", abs(w.t - (-5.0)) < 0.01 && w.p < 0.01,
              String(format: "t %.3f, p %.5f", w.t, w.p))
    }
    check("t-distribution tail matches a table value", abs(Stats.studentTTail(2.228, 10) - 0.025) < 0.001,
          String(format: "%.4f (table: 0.0250)", Stats.studentTTail(2.228, 10)))
    check("normal tail matches a table value", abs(Stats.normalTail(1.96) - 0.025) < 0.001,
          String(format: "%.4f (table: 0.0250)", Stats.normalTail(1.96)))
    if let m = Stats.mannWhitney(g1, g2) {
        check("Mann-Whitney on a fully separated pair", m.u == 0 && m.p < 0.05,
              String(format: "U %.0f, p %.4f", m.u, m.p))
    }
    if let d = Stats.cohensD(g2, g1) {
        check("Cohen's d on a known pair", abs(d - 3.162) < 0.01, String(format: "%.3f", d))
    }
    // Small samples must refuse to make a claim.
    let few = (0..<5).map { fakeTrial(Double($0), .original) }
    let few2 = (0..<5).map { fakeTrial(Double($0) + 2, .sharp) }
    // Sign orientation: every statistic must agree with the printed direction.
    let worseG = (0..<15).map { fakeTrial(Double($0) + 10, .sharp) }
    let betterG = (0..<15).map { fakeTrial(Double($0) + 1, .original) }
    let signCheck = Comparison.pair(("SHARP", worseG), ("ORIGINAL", betterG))
    check("t, U and d all agree with the stated direction",
          signCheck.contains("+9.00") && signCheck.contains("t = +")
            && signCheck.contains("z = +") && signCheck.contains("d           +"),
          "first group worse => all statistics positive")

    check("small samples refuse an inferential claim",
          Comparison.inference(few, few2).contains("too few"), "guard present")

    // A three-group report must name all three and run all three pairings.
    let g = [("ORIGINAL", errs.map { fakeTrial($0, .original) }),
             ("SHARP", errs.map { fakeTrial($0 * 1.2, .sharp) }),
             ("HYBRID", errs.map { fakeTrial($0 * 0.9, .hybrid) })]
    let rep = Comparison.report(g, mode: "A/B/C (45)")
    check("three-group report covers all pairings",
          rep.contains("SHARP vs ORIGINAL") && rep.contains("HYBRID vs ORIGINAL")
            && rep.contains("HYBRID vs SHARP"),
          "3 pairings present")
    check("report is labelled exploratory", rep.contains("EXPLORATORY"), "caveat present")
}

print("\n" + String(repeating: "-", count: 64))
if failures == 0 {
    print("ALL CHECKS PASSED")
    exit(0)
} else {
    print("\(failures) CHECK(S) FAILED")
    exit(1)
}
