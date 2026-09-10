import AppKit
import AVFoundation
import Core
import Foundation
import QuartzCore

/// The whole experiment: state machine, window, key handling, logging.
final class Controller: NSObject, NSApplicationDelegate {

    enum Phase {
        case setup                  // waiting for tracking to come up
        case calibrateForward       // "face forward"
        case calibrateTurnRight     // "turn right" -> measures the yaw sign
        case calibrateReturn        // "back to forward" -> final neutral
        case ready                  // calibrated, waiting to start
        case trial                  // noise playing
        case interTrial             // pause before the next trial
        case rating                 // comfort ratings, before any results are shown
        case finished
    }

    // MARK: State

    private var phase: Phase = .setup
    private let tracker = HeadTracker()
    private var audio: SpatialAudio!
    private var log: TrialLog!
    private let dataDirectory: URL
    private let sessionID: String

    private var schedule: [Double] = Experiment.makeSchedule()
    /// Non-nil in A/B/C mode: the pre-built balanced 15/15/15 plan.
    private var plan: [PlannedTrial]?
    /// Trials in this session — 45 for A/B/C, 30 otherwise.
    private var trialTotal: Int { plan?.count ?? schedule.count }
    /// Comfort ratings, collected after the trials and before any results are shown.
    private var ratings: [Stimulus: Int] = [:]
    private var ratingOrder: [Stimulus] = []
    private var ratingIndex = 0

    /// Sound mode for the session, chosen before the first trial.
    private var mode: SoundMode = .randomAB
    /// Seeded from system entropy at launch and written into every CSV row, so a
    /// session's stimulus sequence is reconstructable after the fact.
    private let rngSeed: UInt64 = UInt64.random(in: UInt64.min...UInt64.max)
    private var rng: SplitMix64
    private var trialIndex = 0                   // 0-based index into `schedule`
    private var recorder: TrialRecorder?
    private var completed: [Trial] = []

    /// Yaw reference captured during calibration, in "positive = right" form.
    private var calibrationNeutral: Double = 0
    private var calibrationStartYaw: Double = 0
    private var calibrationNote = ""

    /// Smoothed yaw actually fed to the renderer (raw yaw is what gets logged).
    private var smoothedYaw: Double = 0
    private var lastRenderTime: Double = CACurrentMediaTime()
    private var renderTimer: Timer?
    private var uiTimer: Timer?
    /// Earliest time the next trial may begin. The trial additionally waits for
    /// the participant to face the calibrated neutral again.
    private var interTrialReadyAt: Double = .infinity
    private var askedToRecentre = false

    /// Non-nil only in `--simulate` mode.
    private var simulator: HeadSimulator?
    private var simTimer: Timer?
    private var simSettledSince: Double?

    private var showDebug = false
    private var speak = true
    private let speech = AVSpeechSynthesizer()
    /// Spoken-prompt voice. nil = the system default.
    private var voice: AVSpeechSynthesisVoice?
    /// Trials requested for this session; the mode supplies the default.
    private var requestedTrials = SoundMode.randomAB.defaultTrialCount
    /// True for --simulate and --geometry-test. These runs override settings in
    /// memory (silent speech, a short inter-trial gap) and must never write
    /// those overrides into the real user's saved preferences.
    private let isHeadlessRun = CommandLine.arguments.contains("--simulate")
        || CommandLine.arguments.contains("--geometry-test")

    // MARK: UI

    private var window: NSWindow!
    private let titleLabel = Controller.label("HEAD-TRACKED LOCALIZATION", size: 22, weight: .bold)
    private let trialLabel = Controller.label("Trial: 0 / \(Experiment.trialCount)", size: 30, weight: .semibold)
    private let trackingLabel = Controller.label("Tracking: …", size: 16, weight: .medium)
    private let instructionLabel = Controller.label("", size: 20, weight: .regular)
    private let debugLabel = Controller.label("", size: 12, weight: .regular, mono: true)
    private let pathLabel = Controller.label("", size: 11, weight: .regular, mono: true)
    private let modeLabel = Controller.label("Sound Mode:", size: 14, weight: .medium)
    private var modeButtons: [NSButton] = []
    private let settingsBox = NSBox()
    private let trialsField = NSTextField(string: "30")
    private let trialsStepper = NSStepper()
    private let trialsNote = Controller.label("", size: 11, weight: .regular)
    private let voicePopup = NSPopUpButton()
    private let speakCheck = NSButton(checkboxWithTitle: "Speak prompts", target: nil, action: nil)
    private let debugCheck = NSButton(checkboxWithTitle: "Show debug info (D)", target: nil, action: nil)
    private let itiPopup = NSPopUpButton()
    private let tolerancePopup = NSPopUpButton()
    /// Voices offered in the picker; index 0 is the system default (nil).
    private var voiceChoices: [AVSpeechSynthesisVoice?] = [nil]

    private static let itiChoices: [Double] = [0.5, 1.0, 1.5, 2.0, 3.0, 5.0]
    private static let toleranceChoices: [Double] = [5, 10, 15, 20, 30, 180]
    private let startButton = NSButton(title: "START TRIAL", target: nil, action: nil)
    private let hereButton = NSButton(title: "HERE  (space)", target: nil, action: nil)
    private let recalButton = NSButton(title: "Recalibrate (C)", target: nil, action: nil)

    override init() {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["P2_DATA_DIR"], !env.isEmpty {
            dataDirectory = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        } else {
            dataDirectory = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/HeadTrackedLocalization")
        }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        sessionID = f.string(from: Date())
        rng = SplitMix64(seed: rngSeed)
        super.init()
        loadSettings()
    }

    /// One line per setting at startup, so what a session actually ran with is
    /// recorded in the log next to its data.
    private func printConfiguration() {
        let split = mode.usesBalancedPlan ? " (\(requestedTrials / 3) per sound)" : ""
        print("""
        [config]
        mode               : \(mode.title)\(split)
        trials             : \(trialTotal)
        seed               : \(rngSeed)
        voice              : \(voice.map { "\($0.name) (\($0.language))" } ?? "system default")\
         \(speak ? "" : "[speech off]")
        gap between trials : \(String(format: "%.1f", Experiment.interTrialInterval)) s
        return-to-centre   : \(Experiment.centreToleranceDeg >= 180 ? "off" : String(format: "±%.0f°", Experiment.centreToleranceDeg))
        """)
    }

    // MARK: - Settings persistence

    // Remembered between launches so a repeated experiment does not have to be
    // reconfigured each time.
    private enum Key {
        static let mode = "soundMode", trials = "trialCount", voice = "voiceIdentifier"
        static let speak = "speakPrompts", iti = "interTrialInterval", tolerance = "centreTolerance"
    }

    private func loadSettings() {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: Key.mode), let m = SoundMode(rawValue: raw) { mode = m }
        requestedTrials = d.object(forKey: Key.trials) as? Int ?? mode.defaultTrialCount
        if let id = d.string(forKey: Key.voice) { voice = AVSpeechSynthesisVoice(identifier: id) }
        if d.object(forKey: Key.speak) != nil { speak = d.bool(forKey: Key.speak) }
        if let v = d.object(forKey: Key.iti) as? Double { Experiment.interTrialInterval = v }
        if let v = d.object(forKey: Key.tolerance) as? Double { Experiment.centreToleranceDeg = v }
        // The restored mode and trial count describe a schedule, so build it.
        // Without this the UI showed the restored settings while the session
        // silently ran the default 30-trial plan.
        requestedTrials = clampTrials(requestedTrials, for: mode)
        rebuildSchedule()
    }

    private func saveSettings() {
        guard !isHeadlessRun else { return }
        let d = UserDefaults.standard
        d.set(mode.rawValue, forKey: Key.mode)
        d.set(requestedTrials, forKey: Key.trials)
        d.set(voice?.identifier, forKey: Key.voice)
        d.set(speak, forKey: Key.speak)
        d.set(Experiment.interTrialInterval, forKey: Key.iti)
        d.set(Experiment.centreToleranceDeg, forKey: Key.tolerance)
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        applyCommandLineOptions()

        audio = SpatialAudio()
        do { try audio.start() } catch {
            instructionLabel.stringValue = "AUDIO ENGINE FAILED: \(error.localizedDescription)"
        }
        do { log = try TrialLog(directory: dataDirectory, sessionID: sessionID) } catch {
            instructionLabel.stringValue = "CANNOT WRITE DATA: \(error.localizedDescription)"
        }
        pathLabel.stringValue = "data -> \(log?.trialsURL.path ?? dataDirectory.path)"
        print("[data] \(log?.trialsURL.path ?? dataDirectory.path)")
        print("[data] \(log?.trajectoryURL.path ?? "")")
        print("[audio]\n" + audio.diagnosticsReport)

        if CommandLine.arguments.contains("--geometry-test") {
            runGeometryTest()
            return
        }
        if CommandLine.arguments.contains("--simulate") {
            let banner = "*** SIMULATION MODE — synthetic head motion, NOT valid experimental data ***"
            print(banner)
            simulator = HeadSimulator()
            speak = false
            Experiment.interTrialInterval = 0.2
            startSimulation()
        } else {
            tracker.onSample = { [weak self] yaw, t in self?.handleSample(yaw: yaw, timestamp: t) }
            tracker.start()
        }
        // Printed last, so it reflects any overrides the run applied.
        printConfiguration()

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }

        renderTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.updateRenderer()
        }
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.advanceInterTrial()
            self?.refresh()
        }

        phase = .setup
        refresh()
    }

    /// `--mode original|sharp|random` and `--trials N`, for scripted runs and
    /// quick tests. Both are optional; the UI selector is the normal route.
    private func applyCommandLineOptions() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--mode"), i + 1 < args.count {
            switch args[i + 1].lowercased() {
            case "original": setMode(.original)
            case "sharp":    setMode(.sharp)
            case "hybrid":   setMode(.hybrid)
            case "random", "randomab", "ab": setMode(.randomAB)
            case "abc", "abc45", "c": setMode(.abc45)
            default: break
            }
        }
        if let i = args.firstIndex(of: "--trials"), i + 1 < args.count,
           let n = Int(args[i + 1]), n > 0 {
            requestedTrials = clampTrials(n, for: mode)
            rebuildSchedule()
            syncSettingsControls()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        audio?.stopNoise()
        audio?.stopEngine()
        tracker.stop()
        log?.close()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Head tracking

    private func handleSample(yaw: Double, timestamp: Double) {
        if phase == .trial, let rec = recorder {
            rec.add(deviceYaw: yaw, timestamp: timestamp)
        }
    }

    /// Head yaw as reported by the active source, already in "positive = right"
    /// form. Real tracking normally; the simulator in `--simulate` mode.
    private var deviceYaw: Double {
        if let sim = simulator { return tracker.yawSign * sim.rawYaw }
        return tracker.yawRight
    }

    /// Current head yaw relative to the active neutral reference, positive = right.
    private var headYaw: Double {
        if phase == .trial, let rec = recorder { return rec.currentYaw }
        return deviceYaw - calibrationNeutral
    }

    /// One-pole smoothing (tau = 40 ms) between the 25 Hz motion samples, so the
    /// rendered image glides instead of stepping. Logged data stays unsmoothed.
    private func updateRenderer() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastRenderTime, 0.1)
        lastRenderTime = now
        let alpha = 1 - exp(-dt / 0.040)
        smoothedYaw += (headYaw - smoothedYaw) * alpha
        audio?.setListenerYaw(smoothedYaw)
    }

    // MARK: - Keys

    /// Returns true when the key was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if event.keyCode == 49 {            // space
            respond(at: event.timestamp)
            return true
        }
        if phase == .rating, let v = Int(chars), (1...7).contains(v) {
            recordRating(v)
            return true
        }
        switch chars {
        case "1": setMode(.original); return true
        case "2": setMode(.sharp); return true
        case "3": setMode(.hybrid); return true
        case "4": setMode(.randomAB); return true
        case "5": setMode(.abc45); return true
        case "c": beginCalibration(); return true
        case "d": showDebug.toggle(); saveSettings(); refresh(); return true
        case "v": speak.toggle(); saveSettings(); refresh(); return true
        case "q": NSApp.terminate(nil); return true
        default: return false
        }
    }

    @objc private func hereClicked() { respond(at: CACurrentMediaTime()) }
    @objc private func startClicked() { respond(at: CACurrentMediaTime()) }
    @objc private func recalClicked() { beginCalibration() }

    // MARK: - Settings panel

    private func buildSettingsBox() {
        settingsBox.title = "Settings"
        settingsBox.titlePosition = .atTop

        // Trials: field plus stepper, stepping by 3 in A/B/C so the three
        // stimuli stay exactly balanced.
        trialsField.alignment = .right
        trialsField.target = self
        trialsField.action = #selector(trialsEdited)
        trialsField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        trialsStepper.target = self
        trialsStepper.action = #selector(trialsStepped)
        trialsStepper.minValue = 1
        trialsStepper.maxValue = 999
        trialsStepper.valueWraps = false
        let trialsRow = NSStackView(views: [trialsField, trialsStepper, trialsNote])
        trialsRow.orientation = .horizontal
        trialsRow.spacing = 6

        // Voice: the installed voices for the interface language, plus the
        // system default. Picking one speaks a sample so it can be judged.
        voicePopup.target = self
        voicePopup.action = #selector(voiceChanged)
        populateVoices()

        speakCheck.target = self
        speakCheck.action = #selector(speakToggled)
        debugCheck.target = self
        debugCheck.action = #selector(debugToggled)
        for b in [speakCheck, debugCheck] { b.refusesFirstResponder = true }

        itiPopup.target = self
        itiPopup.action = #selector(itiChanged)
        for v in Controller.itiChoices { itiPopup.addItem(withTitle: String(format: "%.1f s", v)) }

        tolerancePopup.target = self
        tolerancePopup.action = #selector(toleranceChanged)
        for v in Controller.toleranceChoices {
            tolerancePopup.addItem(withTitle: v >= 180 ? "off" : String(format: "±%.0f°", v))
        }

        let grid = NSGridView(views: [
            [Controller.label("Trials:", size: 13, weight: .regular), trialsRow],
            [Controller.label("Voice:", size: 13, weight: .regular), voicePopup],
            [Controller.label("Gap between trials:", size: 13, weight: .regular), itiPopup],
            [Controller.label("Return-to-centre:", size: 13, weight: .regular), tolerancePopup],
            [NSGridCell.emptyContentView, speakCheck],
            [NSGridCell.emptyContentView, debugCheck],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        let holder = NSView()
        holder.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: holder.topAnchor, constant: 6),
            grid.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -6),
            grid.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 8),
            grid.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -8),
        ])
        settingsBox.contentView = holder
        syncSettingsControls()
    }

    private func populateVoices() {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        var voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
        if voices.isEmpty { voices = AVSpeechSynthesisVoice.speechVoices() }
        voices.sort { ($0.name, $0.language) < ($1.name, $1.language) }

        voiceChoices = [nil] + voices
        voicePopup.removeAllItems()
        voicePopup.addItem(withTitle: "System default")
        for v in voices {
            let quality = v.quality == .premium ? " · premium"
                        : v.quality == .enhanced ? " · enhanced" : ""
            voicePopup.addItem(withTitle: "\(v.name) (\(v.language))\(quality)")
        }
    }

    /// Push the current settings into the controls (after a mode change, a CLI
    /// override, or a load from preferences).
    private func syncSettingsControls() {
        trialsField.stringValue = "\(requestedTrials)"
        trialsStepper.integerValue = requestedTrials
        trialsStepper.increment = Double(mode.trialCountStep)
        trialsNote.stringValue = mode.usesBalancedPlan
            ? "\(requestedTrials / 3) per sound (must be a multiple of 3)"
            : "all \(mode.title)"
        if mode == .randomAB { trialsNote.stringValue = "≈50/50 split" }

        let vIndex = voiceChoices.firstIndex { $0?.identifier == voice?.identifier } ?? 0
        voicePopup.selectItem(at: vIndex)
        speakCheck.state = speak ? .on : .off
        debugCheck.state = showDebug ? .on : .off
        itiPopup.selectItem(at: Controller.itiChoices.firstIndex(of: Experiment.interTrialInterval) ?? 2)
        tolerancePopup.selectItem(at: Controller.toleranceChoices.firstIndex(of: Experiment.centreToleranceDeg) ?? 1)

        // Settings that define the session are locked once it is under way.
        let unlocked = completed.isEmpty
        for c in [trialsField, trialsStepper, itiPopup, tolerancePopup] as [NSControl] {
            c.isEnabled = unlocked
        }
    }

    @objc private func trialsEdited() {
        requestedTrials = clampTrials(trialsField.integerValue, for: mode)
        applyTrialChange()
    }

    @objc private func trialsStepped() {
        requestedTrials = clampTrials(trialsStepper.integerValue, for: mode)
        applyTrialChange()
    }

    private func applyTrialChange() {
        guard completed.isEmpty else { return }
        rebuildSchedule()
        saveSettings()
        syncSettingsControls()
        refresh()
    }

    @objc private func voiceChanged() {
        voice = voiceChoices[max(0, voicePopup.indexOfSelectedItem)]
        saveSettings()
        // Speak a sample so the choice can actually be judged.
        if speak { say("Turn your head towards the sound.") }
    }

    @objc private func speakToggled() {
        speak = speakCheck.state == .on
        saveSettings()
    }

    @objc private func debugToggled() {
        showDebug = debugCheck.state == .on
        refresh()
    }

    @objc private func itiChanged() {
        Experiment.interTrialInterval = Controller.itiChoices[max(0, itiPopup.indexOfSelectedItem)]
        saveSettings()
    }

    @objc private func toleranceChanged() {
        Experiment.centreToleranceDeg = Controller.toleranceChoices[max(0, tolerancePopup.indexOfSelectedItem)]
        saveSettings()
    }

    @objc private func modeChanged(_ sender: NSButton) {
        setMode(SoundMode.allCases[sender.tag])
    }

    /// Rounds a requested trial count into the range the mode allows. A/B/C
    /// needs a multiple of three so the three stimuli stay exactly balanced.
    private func clampTrials(_ n: Int, for m: SoundMode) -> Int {
        let step = m.trialCountStep
        let bounded = min(max(n, step), 999)
        return max(step, (bounded / step) * step)
    }

    private func rebuildSchedule() {
        rng = SplitMix64(seed: rngSeed)
        if mode.usesBalancedPlan {
            plan = Experiment.makeABCPlan(trials: requestedTrials, rng: &rng)
            schedule = plan!.map { $0.angle }
        } else {
            plan = nil
            schedule = Experiment.makeSchedule(count: requestedTrials)
        }
    }

    /// The mode is locked once the first trial has been answered, so a session
    /// cannot silently mix conditions half way through.
    private func setMode(_ m: SoundMode) {
        guard completed.isEmpty else { return }
        let previousDefault = mode.defaultTrialCount
        mode = m
        // Adopt the new mode's default unless the count was deliberately changed.
        if requestedTrials == previousDefault { requestedTrials = m.defaultTrialCount }
        requestedTrials = clampTrials(requestedTrials, for: m)
        rebuildSchedule()
        for (i, b) in modeButtons.enumerated() { b.state = SoundMode.allCases[i] == m ? .on : .off }
        saveSettings()
        syncSettingsControls()
        refresh()
    }

    /// SPACE, the START TRIAL button and the HERE button all funnel through here,
    /// so the on-screen buttons do exactly what the space bar does.
    private func respond(at timestamp: Double) {
        switch phase {
        case .setup:
            beginCalibration()
        case .calibrateForward:
            calibrationStartYaw = deviceYaw
            phase = .calibrateTurnRight
            announce("Turn your head to the right, then press space")
        case .calibrateTurnRight:
            // The direction of the measured change fixes the yaw sign, rather
            // than assuming CoreMotion's convention.
            let delta = deviceYaw - calibrationStartYaw
            if abs(delta) < 10 {
                calibrationNote = String(format: "Only %.1f deg of movement detected - turn further and try again.", delta)
                announce("Not enough movement. Turn further to the right, then press space")
                return
            }
            if delta < 0 {
                tracker.yawSign *= -1
                calibrationNote = String(format: "Yaw sign flipped (measured %.1f deg while turning right).", delta)
            } else {
                calibrationNote = String(format: "Yaw sign confirmed (%.1f deg while turning right).", delta)
            }
            phase = .calibrateReturn
            announce("Face forward again, then press space")
        case .calibrateReturn:
            calibrationNeutral = deviceYaw
            smoothedYaw = 0
            phase = .ready
            announce("Calibration complete. Press space to begin.")
        case .ready:
            startTrial()
        case .trial:
            endTrial(at: timestamp)
        case .interTrial:
            // Debounced during the interval itself, so a second press cannot skip
            // a trial. After it, SPACE overrides the return-to-centre gate.
            if timestamp >= interTrialReadyAt { startTrial() }
        case .rating, .finished:
            break
        }
        refresh()
    }

    // MARK: - Calibration

    private func beginCalibration() {
        endTrialCleanup()
        phase = .calibrateForward
        calibrationNote = ""
        announce("Face straight ahead, then press space")
        refresh()
    }

    // MARK: - Trials

    private func startTrial() {
        guard trialIndex < trialTotal else { beginRatings(); return }
        let target = plan?[trialIndex].angle ?? schedule[trialIndex]
        // The reference frame is the CALIBRATED neutral, established once during
        // calibration and never redefined. Re-zeroing here would place the target
        // relative to wherever the head happened to be left by the previous
        // trial, which lets the forward field walk with the participant and puts
        // targets outside the intended +-90deg — including behind them.
        let neutral = calibrationNeutral
        let startYaw = deviceYaw - neutral
        smoothedYaw = startYaw
        // A/B/C takes the stimulus from the balanced plan; the other modes draw
        // independently from the session's seeded stream.
        let stimulus = plan?[trialIndex].stimulus ?? mode.nextStimulus(rng: &rng)
        recorder = TrialRecorder(index: trialIndex + 1, target: target,
                                 stimulus: stimulus, rngSeed: rngSeed,
                                 neutralYaw: neutral, startTime: CACurrentMediaTime())
        recorder?.add(deviceYaw: deviceYaw, timestamp: CACurrentMediaTime())
        audio.setWorldTargetAngle(target)
        audio.setListenerYaw(startYaw)
        audio.play(stimulus)
        phase = .trial
        if let sim = simulator {
            // The virtual participant turns towards the source, stopping a few
            // degrees short — the same behaviour a real participant shows.
            // The target is in the calibrated frame, so aim there directly.
            sim.aim(at: target + sim.nextBias())
            simSettledSince = nil
        }
    }

    private func endTrial(at timestamp: Double) {
        guard let rec = recorder else { return }
        audio.stopNoise()
        let trial = rec.finish(at: timestamp, trackingActive: simulator == nil && tracker.status.isUsable)
        completed.append(trial)
        log?.write(trial, samples: rec.samples)
        // In Random A/B the stimulus is withheld from the live log too, so a
        // glance at the terminal cannot unblind the participant mid-session.
        let stim = mode.isBlinded ? "hidden" : trial.stimulus.rawValue
        print(String(format: "trial %2d  target %+7.2f  final yaw %+7.2f  error %+7.2f  rt %6.0f ms  samples %d  stimulus %@",
                     trial.index, trial.targetAngle, trial.finalHeadYaw, trial.finalError,
                     trial.responseTimeMS, trial.samples, stim as NSString))
        recorder = nil
        trialIndex += 1

        if trialIndex >= trialTotal {
            beginRatings()
            return
        }

        phase = .interTrial
        interTrialReadyAt = CACurrentMediaTime() + Experiment.interTrialInterval
        askedToRecentre = false
        if speak { say("Trial \(trialIndex + 1)") }
    }

    // MARK: - Comfort ratings

    /// Collected AFTER the last trial and BEFORE any accuracy result is shown,
    /// so knowing how well they did cannot colour the judgement.
    ///
    /// The participant was blinded during the trials, so they cannot map the
    /// names Original/Sharp/Hybrid onto what they heard. Each sound is therefore
    /// played back here, unnamed ("Sound 1 of 3"), in a random order, and rated
    /// as it plays. The CSV records which was which.
    private func beginRatings() {
        endTrialCleanup()
        guard !completed.isEmpty else {
            phase = .finished
            if simulator != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) } }
            refresh(); return
        }
        ratingOrder = Stimulus.allCases.shuffled(using: &rng)
        ratingIndex = 0
        phase = .rating
        playRatingStimulus()
        refresh()
    }

    private func playRatingStimulus() {
        guard ratingIndex < ratingOrder.count else { return }
        audio.stopNoise()
        // Straight ahead, so the rating is about the sound and not its position.
        audio.setWorldTargetAngle(0)
        audio.setListenerYaw(0)
        audio.play(ratingOrder[ratingIndex])
        announce("Sound \(ratingIndex + 1) of 3. Rate 1 to 7 for comfort.")
    }

    private func recordRating(_ value: Int) {
        guard phase == .rating, ratingIndex < ratingOrder.count else { return }
        ratings[ratingOrder[ratingIndex]] = value
        ratingIndex += 1
        if ratingIndex < ratingOrder.count {
            playRatingStimulus()
        } else {
            audio.stopNoise()
            phase = .finished
            announce("Thank you. Results are on screen.")
            printSummary()
            if simulator != nil {
                simTimer?.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            }
        }
        refresh()
    }

    private func endTrialCleanup() {
        interTrialReadyAt = .infinity
        audio?.stopNoise()
        recorder = nil
    }

    /// Called at 10 Hz. Starts the next trial once the inter-trial interval has
    /// elapsed AND the participant has returned to the calibrated neutral.
    ///
    /// The gate is what makes a fixed reference frame workable seated: without
    /// it, a participant who ended the last trial at +80deg would be asked to
    /// find a target at -85deg, a 165deg turn they cannot make in a chair.
    private func advanceInterTrial() {
        guard phase == .interTrial, CACurrentMediaTime() >= interTrialReadyAt else { return }
        if abs(Geo.wrap(headYaw)) <= Experiment.centreToleranceDeg {
            startTrial()
            refresh()
        } else if !askedToRecentre {
            askedToRecentre = true
            announce("Face forward again")
        }
    }

    /// Full statistics, printed and also written next to the CSVs.
    private func printSummary() {
        guard !completed.isEmpty else { return }
        let text = summaryText()
        print(text)
        if let dir = log?.directory, !ratings.isEmpty {
            var csv = "stimulus,comfort_1_to_7,presentation_order\n"
            for (i, s) in ratingOrder.enumerated() {
                csv += "\(s.rawValue),\(ratings[s].map(String.init) ?? ""),\(i + 1)\n"
            }
            let u = dir.appendingPathComponent("ratings_\(sessionID).csv")
            try? csv.data(using: .utf8)?.write(to: u)
            print("ratings: \(u.path)")
        }
        if let dir = log?.directory {
            let url = dir.appendingPathComponent("summary_\(sessionID).txt")
            try? text.data(using: .utf8)?.write(to: url)
            print("summary: \(url.path)")
        }
        print("data: \(log?.trialsURL.path ?? "")")
    }

    private func summaryText() -> String {
        var out = "\n" + String(repeating: "=", count: 66) + "\n"
        out += "SESSION \(sessionID)   mode: \(mode.title)   seed: \(rngSeed)\n"
        out += String(repeating: "=", count: 66) + "\n\n"
        out += Summary(label: "OVERALL", trials: completed).report

        let groups: [(String, [Trial])] = Stimulus.allCases.map { stim in
            (stim.displayName.uppercased(), completed.filter { $0.stimulus == stim })
        }
        for g in groups where !g.1.isEmpty { out += Summary(label: g.0, trials: g.1).report }
        out += Comparison.report(groups, mode: mode.title)

        if !ratings.isEmpty {
            out += "\n\n  COMFORT RATINGS  (1 = extremely unpleasant, 4 = neutral, 7 = extremely comfortable)\n"
            out += "  " + String(repeating: "-", count: 62) + "\n"
            for s in Stimulus.allCases {
                let v = ratings[s].map { "\($0)" } ?? "not rated"
                out += "  " + pad(s.displayName, 20) + v + "\n"
            }
        }
        out += singleSessionCaveat
        return out
    }

    /// Spoken prompts keep the whole session usable with the eyes closed. They
    /// never overlap a trial: only calibration steps and the inter-trial gap.
    private func say(_ text: String) {
        speech.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.rate = 0.52
        u.voice = voice
        speech.speak(u)
    }

    private func announce(_ text: String) {
        instructionLabel.stringValue = text
        if speak { say(text) }
    }

    // MARK: - UI

    private func refresh() {
        trialLabel.stringValue = "Trial: \(min(trialIndex + (phase == .trial ? 1 : 0), schedule.count)) / \(schedule.count)"
        let s = tracker.status
        trackingLabel.stringValue = "Tracking: \(simulator != nil ? "SIMULATED (not real data)" : s.label)    HRTF: \(audio?.hrtfActive == true ? "ACTIVE" : "INACTIVE")"
        trackingLabel.textColor = simulator != nil ? .systemPurple : (s.isUsable ? .systemGreen : .systemOrange)

        switch phase {
        case .setup:
            instructionLabel.stringValue = s.isUsable
                ? "Tracking is live. Press SPACE to calibrate."
                : "Waiting for head tracking — wear AirPods, then press SPACE."
        case .calibrateForward:  break
        case .calibrateTurnRight: break
        case .calibrateReturn:   break
        case .ready:
            instructionLabel.stringValue = "Press SPACE to start trial \(trialIndex + 1) (\(mode.title)). You may close your eyes."
        case .trial:
            instructionLabel.stringValue = "Turn your head towards the sound. Press SPACE when it is in front of you."
        case .interTrial:
            let off = Geo.wrap(headYaw)
            instructionLabel.stringValue = abs(off) <= Experiment.centreToleranceDeg
                ? "…"
                : String(format: "Face forward again (%+.0f deg off) — or press SPACE to go anyway", off)
        case .rating:
            instructionLabel.stringValue =
                "Sound \(min(ratingIndex + 1, 3)) of 3 — how comfortable was this to listen to?\n" +
                "Press 1 (extremely unpleasant) … 4 (neutral) … 7 (extremely comfortable)"
        case .finished:
            let errs = completed.map { abs($0.finalError) }
            let mean = errs.isEmpty ? 0 : errs.reduce(0, +) / Double(errs.count)
            var line = String(format: "Done. %d trials, mean absolute error %.1f deg.", completed.count, mean)
            if mode.isBlinded {
                let counts = Stimulus.allCases
                    .map { s in "\(s.displayName) \(completed.filter { $0.stimulus == s }.count)" }
                    .joined(separator: ", ")
                line += " \(counts). See the summary file for the comparison."
            }
            instructionLabel.stringValue = line
        }

        for b in modeButtons { b.isEnabled = completed.isEmpty }
        // Hide the whole panel once the session is under way, so the participant
        // sees only the trial interface.
        settingsBox.isHidden = !completed.isEmpty || phase == .trial
        debugCheck.state = showDebug ? .on : .off
        speakCheck.state = speak ? .on : .off
        startButton.isEnabled = (phase == .ready || phase == .setup || phase.isCalibration)
        hereButton.isEnabled = (phase == .trial)

        debugLabel.isHidden = !showDebug
        if showDebug {
            let target = recorder?.target ?? audio?.worldTargetAngle ?? 0
            let rel = Geo.relativeAngle(worldTarget: target, headYaw: headYaw)
            debugLabel.stringValue = """
            phase              : \(phase)
            head yaw           : \(f(headYaw)) deg   (smoothed for audio: \(f(smoothedYaw)))
            raw device yaw     : \(f(tracker.rawYaw)) deg   pitch \(f(tracker.pitch))  roll \(f(tracker.roll))
            neutral reference  : \(f(calibrationNeutral)) deg (FIXED at calibration)   yaw sign \(tracker.yawSign > 0 ? "+1" : "-1")
            sound mode         : \(mode.title)   seed \(rngSeed)
            stimulus (this trial): \(recorder?.stimulus.rawValue ?? audio?.currentStimulus.rawValue ?? "-")
            target (world)     : \(f(target)) deg
            relative sound     : \(f(rel)) deg
            listener orient.   : yaw \(f(Double(audio?.listenerYaw ?? 0))) deg (pitch/roll fixed at 0)
            source position    : \(posString(target))
            motion samples     : \(tracker.sampleCount)   trial samples: \(recorder?.samples.count ?? 0)
            \(tracker.diagnosticsReport)
            \(calibrationNote)
            keys: SPACE=HERE  C=recalibrate  D=debug  V=speech(\(speak ? "on" : "off"))  Q=quit
            modes: 1=Original 2=Sharp 3=Hybrid 4=Random A/B 5=A/B/C
            """
        }
    }


    // MARK: - Geometry test

    /// Deterministic end-to-end check of the world/listener geometry, run with
    /// `--geometry-test`.
    ///
    /// This drives the REAL code path — synthetic device yaw -> `deviceYaw` ->
    /// `calibrationNeutral` subtraction -> smoothing -> `setListenerYaw` -> the
    /// live AVAudioEngine nodes — and reads the answers back off the audio
    /// engine itself, not from a parallel calculation.
    ///
    /// Two properties make it able to catch the bugs that matter:
    ///   * the calibrated neutral sits at a non-zero raw device yaw, so any code
    ///     that forgets to subtract it shows up immediately;
    ///   * the head is deliberately left OFF-CENTRE before the trial starts, so
    ///     any code that re-zeroes the frame at trial onset shows up too.
    private func runGeometryTest() {
        let sim = HeadSimulator()
        simulator = sim
        speak = false
        var failures = 0

        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print("  " + (ok ? "PASS" : "FAIL") + " " + pad(name, 44) + detail)
            if !ok { failures += 1 }
        }

        // 1. Calibrate with the head facing forward. The device's raw yaw is far
        //    from zero here, exactly as it is with real AirPods.
        sim.set(trueYaw: 0)
        tracker.yawSign = -1
        calibrationNeutral = deviceYaw
        print("\nGEOMETRY TEST")
        print(String(format: "  calibrated neutral at raw device yaw %+.1f deg (deliberately non-zero)",
                     calibrationNeutral))

        // 2. Leave the head off-centre before the trial begins, as it would be
        //    after the participant answered the previous trial.
        let offCentre = 30.0
        sim.set(trueYaw: offCentre)
        print(String(format: "  head parked at %+.1f deg before the trial starts", offCentre))

        for target in [45.0, -45.0] {
            schedule = [target]
            trialIndex = 0
            completed.removeAll()
            startTrial()

            print(String(format: "\n  target %+.0f deg", target))
            // NOTE: reading `audio.worldTargetAngle` back would only return the
            // number we just passed in, which says nothing about WHICH frame it
            // is measured from. The head-yaw-0 row below is the real test of
            // that: with the head at the calibrated neutral, the relative angle
            // must equal the target.

            let position0 = audio.player.position
            print("    head yaw   expected rel   engine rel   listener yaw   source moved?")

            for head in [0.0, 15, 30, 45, 60, 90].map({ target > 0 ? $0 : -$0 }) {
                sim.set(trueYaw: head)
                handleSample(yaw: deviceYaw, timestamp: CACurrentMediaTime())
                // Run the real smoothing loop to convergence. `updateRenderer`
                // takes its timestep from the wall clock, so a tight loop would
                // leave the one-pole filter unconverged — back-date the clock so
                // each iteration sees a full 100 ms step.
                for _ in 0..<40 {
                    lastRenderTime = CACurrentMediaTime() - 0.1
                    updateRenderer()
                }

                // Read back from the audio engine, not from a separate calculation.
                let listener = audio.listenerYaw
                let world = audio.worldTargetAngle
                let engineRel = Geo.relativeAngle(worldTarget: world, headYaw: listener)
                let expected = Geo.delta(target, head)
                let p = audio.player.position
                let moved = abs(p.x - position0.x) > 0.001 || abs(p.z - position0.z) > 0.001

                print(String(format: "    %+8.0f %14.0f %12.1f %14.1f   %@",
                             head, expected, engineRel, listener, (moved ? "YES" : "no") as NSString))
                check("target \(Int(target)), head \(Int(head)) -> rel \(Int(expected))",
                      abs(Geo.delta(engineRel, expected)) < 1.0,
                      String(format: "engine says %+.1f", engineRel))
                check("  source stayed fixed in world space", !moved,
                      String(format: "(%.3f, %.3f)", p.x, p.z))
            }
            audio.stopNoise()
            recorder = nil
            phase = .ready
        }

        // 3. Target generation must stay inside the forward field.
        var worst = 0.0
        for _ in 0..<2000 {
            for a in Experiment.makeSchedule() { worst = max(worst, abs(a)) }
        }
        check("generated targets stay within +-90deg", worst <= 90.0,
              String(format: "largest magnitude over 60000 targets: %.2f deg", worst))

        print("\n" + String(repeating: "-", count: 62))
        print(failures == 0 ? "GEOMETRY TEST PASSED" : "\(failures) GEOMETRY CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Simulation driver

    /// Feeds synthetic samples at 25 Hz (the AirPods motion rate) and presses
    /// SPACE on the virtual participant's behalf at each phase.
    private func startSimulation() {
        var last = CACurrentMediaTime()
        simTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 25, repeats: true) { [weak self] _ in
            guard let self, let sim = self.simulator else { return }
            let now = CACurrentMediaTime()
            sim.step(dt: now - last)
            last = now
            self.handleSample(yaw: self.deviceYaw, timestamp: now)
            self.driveSimulation(sim: sim, now: now)
        }
    }

    private func driveSimulation(sim: HeadSimulator, now: Double) {
        switch phase {
        case .setup:
            respond(at: now)
        case .calibrateForward:
            sim.aim(at: 0)
            if sim.isSettled { respond(at: now) }
        case .calibrateTurnRight:
            sim.aim(at: 30)                 // a real turn to the right
            if sim.isSettled { respond(at: now) }
        case .calibrateReturn:
            sim.aim(at: 0)
            if sim.isSettled { respond(at: now) }
        case .ready:
            respond(at: now)
        case .trial:
            // Hold still briefly once settled, then answer.
            if sim.isSettled {
                if let since = simSettledSince {
                    if now - since > 0.4 { respond(at: now) }
                } else {
                    simSettledSince = now
                }
            } else {
                simSettledSince = nil
            }
        case .interTrial:
            sim.aim(at: 0)              // return to centre, as a participant would
        case .rating:
            // Fixed placeholder ratings so headless runs complete. Real ratings
            // only ever come from a person pressing 1-7.
            recordRating(4)
        case .finished:
            break
        }
    }

    private func posString(_ azimuth: Double) -> String {
        let p = Geo.position(azimuth: azimuth)
        return String(format: "x %+.2f  y %+.2f  z %+.2f  (+X right, -Z forward)", p.x, p.y, p.z)
    }

    private func f(_ v: Double) -> String { String(format: "%+.1f", v) }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight, mono: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                      : NSFont.systemFont(ofSize: size, weight: weight)
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 0
        return l
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Prototype 2 — Head-Tracked Localization"

        startButton.target = self; startButton.action = #selector(startClicked)
        hereButton.target = self;  hereButton.action = #selector(hereClicked)
        recalButton.target = self; recalButton.action = #selector(recalClicked)
        for b in [startButton, hereButton, recalButton] {
            b.bezelStyle = .rounded
            b.setButtonType(.momentaryPushIn)
            b.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        }
        // Buttons must never steal the space bar from the key handler.
        for b in [startButton, hereButton, recalButton] { b.refusesFirstResponder = true }

        // Mode selector: radio buttons, and keys 1/2/3 do the same thing.
        modeButtons = SoundMode.allCases.enumerated().map { i, m in
            let b = NSButton(radioButtonWithTitle: "\(i + 1)  \(m.title)", target: self,
                             action: #selector(modeChanged(_:)))
            b.tag = i
            b.refusesFirstResponder = true
            b.state = (m == mode) ? .on : .off
            return b
        }
        let modeRow = NSStackView(views: [modeLabel] + modeButtons)
        modeRow.orientation = .horizontal
        modeRow.spacing = 14

        buildSettingsBox()

        let buttons = NSStackView(views: [startButton, hereButton, recalButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [titleLabel, modeRow, settingsBox, trialLabel, trackingLabel,
                                        instructionLabel, buttons, debugLabel, pathLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),
        ])
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Controller.Phase {
    var isCalibration: Bool {
        self == .calibrateForward || self == .calibrateTurnRight || self == .calibrateReturn
    }
}
