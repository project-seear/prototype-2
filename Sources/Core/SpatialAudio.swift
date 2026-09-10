import AVFoundation
import Foundation

/// A continuous mono stimulus rendered through Apple's HRTF binaural renderer.
///
/// Graph:  AVAudioPlayerNode (mono white noise, looping)
///           -> AVAudioEnvironmentNode (renderingAlgorithm = .HRTFHQ)
///           -> main mixer -> output
///
/// The source sits at a FIXED world-space position. Head rotation is applied to
/// the *listener*, never to the source, so the source genuinely stays put in the
/// world while the participant turns.
public final class SpatialAudio {

    /// Playback level. Sound A is normalised to an RMS of 0.10 (-20 dBFS) before
    /// spatialisation and Sound B is matched to it by K-weighted loudness, with
    /// the player gain at 1.0 — so the pre-HRTF source loudness is the same
    /// constant for every trial and both stimuli.
    public static let noiseRMS: Float = StimulusGenerator.originalRMS

    public let engine = AVAudioEngine()
    public let environment = AVAudioEnvironmentNode()
    public let player = AVAudioPlayerNode()

    private let sampleRate: Double
    private let monoFormat: AVAudioFormat
    /// One pre-rendered buffer per stimulus. Both feed the identical graph.
    private var buffers: [Stimulus: AVAudioPCMBuffer] = [:]

    /// The stimulus currently scheduled.
    public private(set) var currentStimulus: Stimulus = .original

    /// Latest values, for the UI/diagnostics.
    public private(set) var worldTargetAngle: Double = 0
    public private(set) var listenerYaw: Double = 0
    public var relativeAngle: Double { Geo.relativeAngle(worldTarget: worldTargetAngle, headYaw: listenerYaw) }

    public init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        self.monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

        engine.attach(player)
        engine.attach(environment)
        engine.connect(player, to: environment, format: monoFormat)
        engine.connect(environment, to: engine.mainMixerNode, format: stereo)

        // Headphone rendering: we always render binaurally for headphones, and
        // never let the system pick speaker rendering.
        environment.outputType = .headphones
        environment.reverbParameters.enable = false
        environment.renderingAlgorithm = .auto

        // Genuine HRTF, not amplitude panning.
        player.renderingAlgorithm = .HRTFHQ
        player.sourceMode = .pointSource
        player.pointSourceInHeadMode = .mono
        player.obstruction = 0
        player.occlusion = 0
        player.reverbBlend = 0

        // Constant distance => no distance cue. Reference distance equals the
        // source distance, so attenuation is 0 dB at all times.
        let atten = environment.distanceAttenuationParameters
        atten.distanceAttenuationModel = .inverse
        atten.referenceDistance = Float(Geo.sourceDistance)
        atten.maximumDistance = Float(Geo.sourceDistance * 100)
        atten.rolloffFactor = 0

        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        setListenerYaw(0)
        setWorldTargetAngle(0)

        for s in Stimulus.allCases {
            buffers[s] = StimulusGenerator.buffer(s, format: monoFormat)
        }
    }

    // MARK: - Control

    public func start() throws {
        try engine.start()
    }

    public func stopEngine() {
        player.stop()
        engine.stop()
    }

    /// World-space azimuth of the source. Set once at the start of a trial and
    /// never touched again while the participant turns.
    public func setWorldTargetAngle(_ degrees: Double) {
        worldTargetAngle = degrees
        let p = Geo.position(azimuth: degrees)
        player.position = AVAudio3DPoint(x: Float(p.x), y: Float(p.y), z: Float(p.z))
    }

    /// Listener yaw in degrees, positive = head turned to the right.
    ///
    /// AVAudio3DAngularOrientation defines its yaw axis as pointing towards the
    /// bottom of the listener's head with positive yaw clockwise, i.e. positive
    /// yaw turns the listener's forward vector from -Z towards +X (to the right).
    /// That matches this prototype's convention directly, so no sign flip.
    /// `verify` measures this rather than trusting it.
    public func setListenerYaw(_ degrees: Double) {
        listenerYaw = degrees
        environment.listenerAngularOrientation =
            AVAudio3DAngularOrientation(yaw: Float(degrees), pitch: 0, roll: 0)
    }

    /// Start the chosen stimulus, looping. Only the source waveform differs
    /// between stimuli — the graph, HRTF, listener and position are untouched.
    public func play(_ stimulus: Stimulus) {
        currentStimulus = stimulus
        guard let buffer = buffers[stimulus] else { return }
        player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
        player.play()
    }

    public func stopNoise() {
        player.stop()
    }

    /// Peak sample value of a stimulus buffer, for the clipping check.
    public func peak(of stimulus: Stimulus) -> Float {
        guard let b = buffers[stimulus] else { return 0 }
        let p = b.floatChannelData![0]
        var m: Float = 0
        for i in 0..<Int(b.frameLength) { m = max(m, abs(p[i])) }
        return m
    }

    public func samples(of stimulus: Stimulus) -> [Float] {
        guard let b = buffers[stimulus] else { return [] }
        let p = b.floatChannelData![0]
        return (0..<Int(b.frameLength)).map { p[$0] }
    }

    // MARK: - Diagnostics

    /// True only if the HRTF algorithm is actually applicable to the current
    /// output format *and* is the algorithm in force on the source bus.
    public var hrtfActive: Bool {
        return applicableAlgorithms.contains(.HRTFHQ) && player.renderingAlgorithm == .HRTFHQ
    }

    /// `applicableRenderingAlgorithms` is bridged as [NSNumber]; unwrap it.
    public var applicableAlgorithms: [AVAudio3DMixingRenderingAlgorithm] {
        environment.applicableRenderingAlgorithms.compactMap {
            AVAudio3DMixingRenderingAlgorithm(rawValue: $0.intValue)
        }
    }

    public var diagnosticsReport: String {
        let algs = applicableAlgorithms.map(SpatialAudio.name(of:)).joined(separator: ", ")
        return """
        output format      : \(engine.mainMixerNode.outputFormat(forBus: 0))
        source algorithm   : \(SpatialAudio.name(of: player.renderingAlgorithm))
        applicable         : \(algs)
        environment output : headphones
        HRTF active        : \(hrtfActive ? "YES" : "NO")
        stimuli loaded     : \(Stimulus.allCases.map(\.rawValue).joined(separator: ", "))
        loudness (LUFS)    : \(Stimulus.allCases.map { String(format: "%@ %.2f", $0.rawValue, Loudness.lufs(samples(of: $0), sampleRate: sampleRate)) }.joined(separator: "   "))
        source distance    : \(Geo.sourceDistance) m, attenuation disabled
        """
    }

    public static func name(of a: AVAudio3DMixingRenderingAlgorithm) -> String {
        switch a {
        case .equalPowerPanning: return "EqualPowerPanning"
        case .sphericalHead: return "SphericalHead"
        case .HRTF: return "HRTF"
        case .soundField: return "SoundField"
        case .stereoPassThrough: return "StereoPassThrough"
        case .HRTFHQ: return "HRTFHQ"
        case .auto: return "Auto"
        @unknown default: return "unknown(\(a.rawValue))"
        }
    }
}

/// Deterministic RNG so the noise is identical across runs and verifiable.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// A fair coin flip, taken from a high bit of the mixed output.
    public mutating func nextBool() -> Bool { (next() >> 33) & 1 == 1 }

    /// Uniform in [-1, 1).
    public mutating func nextUniform() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0) * 2 - 1
    }
}
