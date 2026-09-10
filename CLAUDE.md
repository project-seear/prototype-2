# Prototype 2 — head-tracked localization

Swift/AppKit macOS app. World-fixed sound source, AirPods head tracking, 30
trials, SPACE = "the sound is in front of me now". Two stimuli under one
identical HRTF pipeline (Sound A = original white noise, Sound B = sharp grain
texture) with a blinded Random A/B mode. See README.md.

## Files
- `Sources/Core/Geometry.swift` — coordinate convention (+X right, −Z forward,
  0° = ahead, + = right), wrapping, `relativeAngle(worldTarget:headYaw:)`.
- `Sources/Core/SpatialAudio.swift` — AVAudioEngine graph. Source at a fixed
  world position; head rotation goes to `listenerAngularOrientation` only.
  Identical for both stimuli — only which buffer is scheduled differs.
- `Sources/Core/Stimulus.swift` — Sound A (unchanged white noise) and Sound B
  (grain train), RBJ biquads, BS.1770 loudness matching, `SoundMode`.
- `Sources/Core/Stats.swift` — summaries and N-way stimulus comparison (table,
  all pairings, Welch, Mann-Whitney, Cohen's d, small-sample guard). All
  statistics are oriented a-minus-b to match the printed header.
- `Sources/Core/Experiment.swift` — schedules, incl. the balanced 45-trial
  A/B/C plan (15 bins x 3 stimuli, shuffled, max run 3).
- `Sources/Core/TrialLog.swift` — `Trial`/`YawSample` and the two CSV writers.
- `Sources/Prototype2/HeadTracker.swift` — `CMHeadphoneMotionManager` → yaw.
- `Sources/Prototype2/Experiment.swift` — stratified schedule, `TrialRecorder`.
- `Sources/Prototype2/AppUI.swift` — phase machine, window, key handling, and
  the on-screen Settings panel (mode, trials, speech voice, inter-trial gap,
  return-to-centre tolerance; persisted in UserDefaults).
- `Sources/Prototype2/Simulation.swift` — `--simulate` virtual participant.
- `Sources/diag/main.swift` — stimulus parameter sweep; how Sound B was tuned.
- `Sources/verify/main.swift` — offline-rendered measurement of audio+geometry,
  stimulus properties, randomisation and the statistics.

## Run
```
./build.sh                 # -> build/Prototype2.app (signed; needed for CoreMotion)
./run.sh                   # experiment, data -> ./data
./verify.sh                # measured checks, non-zero exit on failure
./build/Prototype2.app/Contents/MacOS/Prototype2 --simulate --mode abc45
./build/Prototype2.app/Contents/MacOS/Prototype2 --geometry-test   # reference-frame check
swift run -c release diag   # re-run the Sound B parameter sweep
```

## Working rules
- Keep it simple; smallest working implementation. No new dependencies.
- Never replace HRTF with left/right volume panning.
- The source is fixed in world space. Rotate the *listener*, never the source.
- Don't add distance cues or extra effects; the source stays mono pre-HRTF.
- Sounds A and B are FROZEN baselines shared with earlier sessions. Never change
  them. `swift run -c release diag` prints an FNV hash of each; A must stay
  13103158ac5a43bb and B 527fab1e6dbd247f after any edit to Stimulus.swift.
- Only the waveform may differ between stimuli — never the HRTF, listener,
  position, distance or coordinates.
- Level-match stimuli by K-weighted loudness, never by RMS.
- Keep Random A/B blind in the participant UI and in the live terminal log.
- Measure claims about the audio, don't assume them. Run `./verify.sh` before calling
  an audio or geometry change done; run `--simulate` before calling a trial-loop
  or logging change done.
- Yaw sign and tracking availability are detected at runtime, not hardcoded.
- The calibrated neutral is the fixed reference frame for the WHOLE session.
  Never re-zero it at trial start — that makes the forward field walk with the
  participant and pushes targets outside +-90deg (and behind them). Run
  `--geometry-test` before calling any geometry change done.
- Pitch and roll are ignored on purpose.
