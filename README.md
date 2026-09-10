# Prototype 2 — Head-Tracked Spatial Audio Localization

A world-fixed sound source is placed at a random azimuth in front of the
participant. The participant turns their head until the sound is centred, then
presses **SPACE**. Thirty trials, eyes closed, no screen needed.

**Sound profile comparison.** Three stimuli are compared under an identical HRTF
pipeline: **A / Original** (baseline white noise), **B / Sharp** (transient-dense
and band-limited, for a compact percept) and **C / Hybrid** (A's low-frequency
body plus B's transient highs, split at the duplex-theory crossover). Four modes:
Original, Sharp, blinded Random A/B, and the blinded **45-trial A/B/C** block
(15 of each) that is the main experiment.

---

## 1. Technology stack

| Layer | Choice |
|---|---|
| Language | Swift 5.9 / 6.x (Swift 6.3 toolchain) |
| Build | SwiftPM + a 40-line `build.sh` that assembles a signed `.app` |
| UI | AppKit, programmatic, single window |
| Head tracking | **CoreMotion `CMHeadphoneMotionManager`** (AirPods, macOS 14+) |
| Spatial audio | **AVFoundation `AVAudioEnvironmentNode`, `renderingAlgorithm = .HRTFHQ`** |
| Data | Two CSVs written and `fsync`ed after every trial |

No third-party dependencies. Everything is a macOS system framework.

## 2. Why this stack

**Head tracking decided the stack.** AirPods Pro 2 orientation is exposed on
macOS through exactly one API: `CMHeadphoneMotionManager` in CoreMotion, added
for macOS 14.0. It has no Python, C++ or Unity binding — Unity's `InputDevice`
head tracking does not cover AirPods on macOS, and the Python `pyobjc` route
still needs a signed app bundle to get past TCC, at which point the Python is
just overhead around an Objective-C call. Native Swift is the shortest path to
the only API that works.

**Given Swift, `AVAudioEnvironmentNode` is the right renderer.** It provides a
real HRTF (`.HRTFHQ`), a world-space source position and an independent listener
orientation — precisely the world-fixed-source / rotating-listener model this
experiment needs, with no manual coordinate maths in the audio path. It is a
first-party, long-maintained framework, and the source stays mono until the
HRTF, so nothing else can colour the spatial cues.

**Alternatives considered.** *PHASE* is Apple's newer spatial engine but is
built around game-style scene graphs and geometry occlusion; it is more API for
no gain here. *OpenAL Soft* (used in Prototype 1) has an excellent HRTF and is
open source, but pairing it with Swift-only head tracking means running the
orientation over a process/FFI boundary for no accuracy benefit. *Python* was
rejected for the tracking reason above. Latency matters and every layer removed
is latency removed, so the whole thing is one native process.

Prototype 1's code was not reused: it is Python/OpenAL with no head tracking and
a different experimental question, so there was nothing worth carrying across
except the discipline of *measuring* the HRTF rather than assuming it.

## 3. Project structure

```
Test Prototype 2/
├── Package.swift
├── build.sh                    # builds + signs build/Prototype2.app
├── run.sh                      # build, then launch with data going to ./data
├── Resources/Info.plist        # NSMotionUsageDescription lives here
├── Sources/
│   ├── Core/                   # shared, hardware-free, unit-testable
│   │   ├── Geometry.swift      # coordinate convention, wrapping, world->head transform
│   │   ├── SpatialAudio.swift  # AVAudioEngine graph, HRTF (identical for both stimuli)
│   │   ├── Stimulus.swift      # Sound A + Sound B, biquads, BS.1770 loudness, SoundMode
│   │   ├── Stats.swift         # summaries, Welch, Mann-Whitney, Cohen's d
│   │   └── TrialLog.swift      # Trial/YawSample records + CSV writers
│   ├── Prototype2/             # the experiment app
│   │   ├── main.swift
│   │   ├── HeadTracker.swift   # CMHeadphoneMotionManager -> yaw
│   │   ├── Experiment.swift    # trial schedule + per-trial accumulator
│   │   ├── Simulation.swift    # --simulate virtual participant (dev only)
│   │   └── AppUI.swift         # state machine, window, key handling
│   ├── diag/main.swift         # stimulus parameter sweep (how Sound B was tuned)
│   └── verify/main.swift       # measured validation, no hardware needed
└── data/                       # CSV output lands here
```

## 4. Installation / setup

Requires macOS 14+ (developed on macOS 26.5) and Xcode command line tools.

```bash
cd "Test Prototype 2"
./build.sh
```

That is the whole setup — no package manager, no dependencies.

The build produces `build/Prototype2.app`. A **bundle** is required, not a bare
executable: CoreMotion refuses to start headphone motion updates unless the
process is a code-signed bundle declaring `NSMotionUsageDescription`.

On first run macOS asks for **Motion & Fitness** access. Grant it. If it was
denied, re-enable it at System Settings → Privacy & Security → Motion & Fitness.

> The default signature is ad-hoc, whose code hash changes on every build, so
> macOS may re-ask for motion access after a rebuild. To avoid that, build once
> with a stable identity:
> `CODESIGN_ID="Apple Development: you@example.com" ./build.sh`

## 5. Running

```bash
./verify.sh       # optional but recommended: measured audio/geometry checks
./run.sh          # build + run the experiment, data -> ./data
```

`run.sh` launches through `open` so the motion permission is attributed to the
app rather than to your terminal. The app's output goes to
`data/session_<timestamp>.log`, which `run.sh` tails so the per-trial lines still
appear live in your terminal. (`open --stdout` cannot be pointed at
`/dev/stdout` — LaunchServices rejects it with `-10810` — hence the log file.)

Arguments are forwarded, so `./run.sh --mode random --trials 10` works.

Development modes:

```bash
./run.sh --simulate --mode random      # virtual participant, no hardware needed
./verify.sh                            # offline measurement of the audio path
swift run -c release diag              # stimulus parameter sweep
```

Keys: **SPACE** = HERE · **1**–**5** = Original / Sharp / Hybrid / Random A/B /
A/B/C · **C** = recalibrate · **D** = debug panel · **V** = speech on/off ·
**Q** = quit. During the comfort-rating step, **1**–**7** are the ratings.

Scripted runs: `--mode original|sharp|random` and `--trials N`.

## 6. How head tracking works

`CMHeadphoneMotionManager` delivers `CMDeviceMotion` from the AirPods' IMU —
measured at **50 Hz** in a real session on AirPods Pro 2 / macOS 26. Only `attitude.yaw` is used; pitch and roll are read for the debug panel and
then discarded.

- Yaw is **unwrapped** on arrival (`Geo.unwrap`) so it stays continuous across
  ±180° and head rotation can accumulate.
- CoreMotion reports yaw positive to the *left*. Rather than trusting that,
  calibration **measures** the sign from an actual rightward head turn and sets
  `HeadTracker.yawSign` accordingly.
- The tracker retries `startDeviceMotionUpdates` once a second, so connecting
  AirPods after launching the app works.
- Status is derived, not assumed: authorization state, whether any sample has
  arrived, and sample age (>0.5 s ⇒ `STALLED`).
- Small fluctuations: the **logged** trajectory is raw, while the yaw fed to the
  renderer passes through a one-pole filter (τ = 40 ms) at 60 Hz, which bridges
  the sample grid so the image glides rather than steps.

## 7. How HRTF spatialization works

```
AVAudioPlayerNode (mono white noise, looped)
    -> AVAudioEnvironmentNode   renderingAlgorithm = .HRTFHQ
                                outputType         = .headphones
                                reverb             = off
    -> main mixer -> output
```

The source is placed at a **world-space** point and never moves during a trial:
azimuth `a` ⇒ `(1.5·sin a, 0, −1.5·cos a)`. Head rotation is applied only to
`listenerAngularOrientation.yaw`. Distance is fixed at 1.5 m with the rolloff
factor set to 0, so level is never a distance cue.

This is checked rather than believed. `./verify.sh` renders the real graph offline and
measures the binaural output:

```
azimuth   ILD dB (L−R)   ITD µs (+ = right)
 −90         +14.82           −729
 −60         +16.09           −542
 −30         +10.16           −250
   0          −0.51             −0
 +30         −11.81           +250
 +60         −15.94           +542
 +90         −14.21           +750
```

An interaural **time** difference of 542 µs at 60° is the signature of a real
HRTF; the same render forced to `.equalPowerPanning` measures **0 µs**, because
amplitude panning cannot produce one. (The ILD dipping slightly from ±60° to
±90° is genuine head-shadow diffraction, and is itself further evidence this is
not a panner — a panner would be monotonic to 90°.)

## 7a. The two stimuli

Both are mono, 4-second looping buffers from a seeded `SplitMix64` (identical run
to run), played at unity gain into the *same* graph. Only the waveform differs.

### Sound A — Original (frozen baseline)

Flat **white noise**, RMS-normalised to **0.10 (−20 dBFS)** pre-HRTF. This is
byte-for-byte the original Prototype 2 stimulus: same generator, same seed
(`0xC0FFEE`), same level. `verify` asserts its RMS is still exactly 0.10.

### Sound B — Sharp (frozen)

A dense, irregular train of short band-limited noise bursts:

| Parameter | Value | Why |
|---|---|---|
| Grain | 1.5 ms Hann-windowed noise burst | sharp onset without the spectral splatter of a raw click |
| Rate | 400 grains/s, mean | many onsets/s; fuses into a continuous texture |
| Jitter | ±50% of the interval, uniform | no periodicity ⇒ no buzz, rhythm or pitch |
| High-pass | 600 Hz, 24 dB/oct | removes the diffuse low end |
| Low-pass | 10 kHz, 24 dB/oct | keeps it from being hissy or piercing |
| Presence | +4 dB at 3.5 kHz, Q 0.9 | lifts the band carrying HRTF cues |
| Level | K-weighted loudness matched to Sound A | so the comparison is not a level comparison |

**Why it should localise better.** Three reasons, each addressing a specific
weakness of steady broadband noise:

1. **Onsets.** The binaural system weights the *rising* part of an envelope far
   more heavily than the steady portion, and transient sounds are the most
   precisely localised stimuli there are. Steady noise offers one continuous,
   ambiguous stream; Sound B re-presents a fresh, unambiguous binaural snapshot
   hundreds of times a second. Measured crest factor **7.71 vs 1.73** for white
   noise — it is genuinely transient, not noise with a filter on it.
2. **Removing the useless low end.** Below ~300 Hz the wavelength is far longer
   than the head, so an HRTF produces almost no level difference and the sound
   is heard as diffuse and "inside the head" — exactly the reported "subwoofer
   filling the space". Sound B carries **93% less energy below 300 Hz**, while
   keeping 600 Hz–1.5 kHz, where fine-structure ITD still works.
3. **Feeding the cue bands.** Sound B puts **76% more energy in 2–8 kHz**, where
   head-shadow ILD and pinna spectral cues live — the bands Apple's HRTF actually
   shapes.

**How those numbers were chosen.** Not by ear or by guesswork — by sweep. The
`diag` tool measures each candidate for envelope periodicity (would it buzz?),
short-time level variation (would it flutter or gap?), crest factor and onset
density (is it still transient?). 400 grains/s at 1.5 ms was the best joint
optimum: envelope periodicity **0.075**, which is essentially white noise's own
**0.056**, with 4.5× the crest factor.

    swift run -c release diag     # re-run the parameter sweep

### Sound C — Hybrid

The hypothesis being tested is that A and B fail in opposite ways: A is broad and
easy to find but imprecise; B is precise but easy to miss. Hybrid is built to
take the useful half of each.

It is **not** A and B played together. That would put two full-bandwidth signals
on top of each other and mostly reproduce A's diffuseness. Instead the two
layers are split at the **duplex-theory crossover (1.5 kHz)** so their spectra
are complementary and each mechanism operates only where it is physiologically
effective:

| Band | Source | Cue it carries |
|---|---|---|
| 350 Hz – 1.5 kHz | Sound A's steady white noise | fine-structure ITD — broad, robust "which way is it" |
| 1.5 – 10 kHz | Sound B's grain train (+4 dB at 3.5 kHz) | envelope ITD, head-shadow ILD, pinna spectral cues — sharpens the centre |

The **350 Hz low-cut** is the one place Hybrid departs from simply reusing A. It
was set on principle: fine-structure ITD is usable to roughly 1.3–1.5 kHz, while
below ~300 Hz the wavelength so exceeds the head that the HRTF yields almost no
level difference and the sound is heard as diffuse and inside the head. A
4th-order cut at 350 Hz is ~24 dB down by 175 Hz, so the rumble goes and
everything from ~400 Hz up survives.

> An earlier attempt used a 120 Hz cut. Verification caught that it gave Hybrid
> **more** sub-300 Hz energy than Original (0.249 vs 0.102) — loudness-normalising
> a band-limited layer boosts the bass — which would have made Hybrid *more*
> diffuse than the baseline, the opposite of the intent.

The two layers are mixed at **equal K-weighted loudness**, a neutral split fixed
in advance. Measured against the other two:

| | Original | Sharp | Hybrid |
|---|---:|---:|---:|
| crest factor | 1.73 | 7.71 | **5.89** |
| energy < 300 Hz | 0.102 | 0.007 | **0.078** |
| energy 350 Hz–1.5 kHz | 0.178 | 0.210 | **0.622** |
| energy 2–8 kHz | 0.410 | 0.724 | **0.456** |
| loudness | −16.86 LUFS | −16.86 | **−16.86** |

Hybrid is intermediate on transient character and high-band cue energy, carries
less rumble than either A or B would suggest, and has 3.5× A's energy in the
fine-structure ITD band — the "broad directional" component.

**No angle-dependent processing.** The brief's "becomes better defined as you
approach the source" is an *emergent* property, not something the code does: the
minimum audible angle is smallest near the midline, so the high-band cues
naturally discriminate best near centre. Making the stimulus change with angle
would be a stimulus-specific spatialisation trick (forbidden) and would leak a
non-spatial cue to the answer, invalidating the experiment.

### Loudness matching

Equal RMS is *not* equal loudness — Sound B's energy sits where the ear is most
sensitive, so RMS-matching would leave it audibly louder and confound the
comparison with a level difference. Both are therefore matched by **ITU-R BS.1770
K-weighted loudness** to **−16.86 LUFS**, verified to within 0.01 LU. Sound A's
absolute level is unchanged; Sound B is scaled to meet it.

## 7b. On-screen settings

Everything needed to configure a session is in the **Settings** panel above the
trial display. It disappears once the session starts, so the participant sees
only the trial interface, and the session-defining settings lock after the first
answered trial so a run cannot change shape halfway through.

| Setting | Notes |
|---|---|
| **Sound mode** | radio buttons, or keys `1`–`5` |
| **Trials** | field + stepper. In A/B/C mode it steps by 3 and shows the per-sound count, since the three stimuli must stay exactly balanced |
| **Voice** | the installed speech voices for your interface language, plus "System default". Choosing one speaks a sample immediately so you can judge it |
| **Speak prompts** | on/off, same as key `V` |
| **Gap between trials** | 0.5–5 s inter-trial interval |
| **Return-to-centre** | how close to neutral you must face before the next trial starts (±5° to ±30°, or *off* to disable the gate) |
| **Show debug info** | same as key `D` |

All of these persist in `UserDefaults` between launches, so a repeated experiment
does not have to be reconfigured each time. `--mode` and `--trials` on the command
line override them for that run and update the controls to match.

> Setting **Return-to-centre** to *off* removes the gate that keeps the fixed
> reference frame usable while seated. It is there for testing; leave it on for
> real sessions.

## 7b2. Modes and blinding

| Mode | Key | Behaviour |
|---|---|---|
| Original | `1` | every trial uses Sound A |
| Sharp | `2` | every trial uses Sound B |
| Hybrid | `3` | every trial uses Sound C |
| Random A/B | `4` | independent fair coin flip per trial, 30 trials |
| A/B/C balanced | `5` | equal thirds, 45 trials — **the main experiment** |

Random A/B draws each trial independently rather than shuffling a balanced list,
because a balanced list becomes predictable towards the end of a block. The cost
is that the split is only approximately even; the actual counts are always
reported.

**The 45-trial A/B/C schedule.** The angular range is cut into 15 equal bins and
each stimulus gets exactly one trial in every bin, with the angle drawn uniformly
inside it. All three stimuli therefore see the *same* distribution of target
angles, so a difference between them cannot be an artefact of one having drawn
easier angles — which independent sampling of only 15 trials could easily do. The
45 trials are then shuffled, rejecting any order with a run of more than 3
identical stimuli (a plain shuffle readily produces runs of 5–6, and a streak
that long invites adaptation, which would bias both localisation and the comfort
rating).

The session seed comes from system entropy, is printed at startup and written
into every CSV row (`rng_seed`), so any session's stimulus sequence and target
angles can be reconstructed exactly.

**Blinding.** In Random A/B the stimulus is withheld from the participant UI
*and* from the live terminal log (it prints `stimulus hidden`), so a glance at
either cannot unblind the run. It is still written to the CSV for analysis, and
the debug panel (**D**) reveals it for development. The mode selector locks once
the first trial is answered, so a session cannot silently mix conditions.

## 8. How calibration works

Three prompted steps, spoken aloud as well as shown, driven entirely by SPACE:

1. **"Face straight ahead"** → captures the starting heading.
2. **"Turn your head to the right"** → measures the change. Less than 10° is
   rejected with a retry prompt (this catches dead tracking). The *direction* of
   the change fixes the yaw sign empirically.
3. **"Face forward again"** → captures the neutral reference.

Press **C** at any time to recalibrate.

The calibrated neutral defines the **fixed reference frame for the entire
session**. It is captured once and never redefined — not between trials, not
after a response. Every target angle, every listener orientation and every
recorded head yaw is expressed in that one frame.

> **This was a bug until it was fixed.** Earlier versions re-zeroed the neutral
> at the start of every trial, on the theory that it kept gyro drift out of the
> measurement. It did — but it also let the forward field walk with the
> participant: whatever direction they were facing when a trial began became the
> new 0°, so targets accumulated away from true forward. In a real 30-trial run,
> 33% of targets ended up outside the intended ±90° field, the worst at −233°
> (i.e. behind the participant). See §11a.

**Return to centre between trials.** Because the frame is fixed, the participant
must be facing roughly forward when a trial starts, or a target at the far side
of the field would be physically unreachable in a chair. After the inter-trial
interval the app waits until the head is within **±10°** of the calibrated
neutral, prompting "Face forward again" and showing the current offset. SPACE
overrides the gate if needed.

**The drift trade-off.** With a fixed frame, gyro drift now accumulates across a
session instead of being reset away each trial. This is the correct trade — a
drifting *measurement* is a known, visible error, whereas a drifting *reference
frame* silently invalidates the experimental design. Drift is also now
self-announcing: if the participant is physically facing forward but the app
still says "face forward again", the gyro has drifted. Press **C** to
recalibrate. Per-sample `raw_device_yaw_deg` in the trajectory CSV lets drift be
quantified after the fact.

## 9. Where the data goes

`./data/` (set by `run.sh`; override with `P2_DATA_DIR`; defaults to
`~/Documents/HeadTrackedLocalization`). The full path is printed at startup and
shown at the bottom of the window.

**`trials_<timestamp>.csv`** — one row per trial:

`trial, target_angle_deg, initial_head_yaw_deg, neutral_device_yaw_deg,
final_head_yaw_deg, final_error_deg, abs_error_deg, total_rotation_deg,
response_time_ms, trial_start_iso, trial_response_iso, samples, tracking_active,
stimulus, rng_seed`

`stimulus` is `original`, `sharp` or `hybrid` for every trial, so the file splits cleanly
into All / Original / Sharp. No previously existing column was removed.

**`summary_<timestamp>.txt`** — the statistics below, written at the end of the
session next to the CSVs.

**`ratings_<timestamp>.csv`** — `stimulus, comfort_1_to_7, presentation_order`,
written when comfort ratings were collected.

**`trajectory_<timestamp>.csv`** — every motion sample in every trial:

`trial, t_ms, head_yaw_deg, raw_device_yaw_deg, relative_sound_angle_deg`

`final_error_deg` is `wrap(target − final_head_yaw)`: positive means the source
was still to the participant's right when they answered. `initial_head_yaw_deg`
is 0 by construction (the per-trial re-zero); the absolute heading it corresponds
to is `neutral_device_yaw_deg`. Both files are flushed after every trial, so an
abandoned session still leaves valid data.

## 10. Running the 30-trial experiment

1. Put on AirPods. Quiet room. `./run.sh`.
2. Confirm the window shows **Tracking: ACTIVE** and **HRTF: ACTIVE**.
3. **Pick a sound mode** (radio buttons, or keys 1/2/3). Random A/B is the
   important one; Original and Sharp are for getting a feel for each stimulus.
4. Press SPACE through the three calibration prompts.
5. Press SPACE to start trial 1, then close your eyes.
6. For each trial: the sound starts → turn your head until it is dead ahead →
   press SPACE. The next trial starts automatically 1.5 s later, announced by
   voice. Nothing on screen is needed from here on.
7. After trial 30 the statistics are printed and written to
   `summary_<timestamp>.txt`.

The recommended sequence is one 30-trial block per mode, with Random A/B being
the one that actually answers the question. Use `--trials N` for a quick check.

## 10a. Statistics

At the end of a session the app reports, for **Overall**, **Original** and
**Sharp** separately: n, mean and median absolute error, percentage within ±5°,
±10° and ±15°, mean and median response time, mean and median total head
rotation, and signed bias.

When a session contains more than one stimulus it also prints a side-by-side
table of all metrics, a note of which stimulus leads on each, and **every
pairwise comparison** (Hybrid vs Original, Hybrid vs Sharp, Original vs Sharp)
with mean and median difference plus:

- **Welch's t-test** on trial-level absolute error (unequal variance)
- **Mann-Whitney U** with tie correction (robust to the skew angular errors always have)
- **Cohen's d** with a pooled SD, labelled negligible/small/medium/large

Below 10 trials in either condition the app refuses to compute these at all and
says so. Every statistic is oriented the same way as the printed header (`a − b`),
so t, U and d never disagree in sign. Output is labelled EXPLORATORY and carries
a standing limitations block.

### Comfort ratings

After the last trial — and **before any accuracy result is shown** — the
participant rates each sound 1–7 for comfort. They were blinded during the
trials, so they cannot map the names onto what they heard; each sound is instead
played back unnamed ("Sound 1 of 3") in random order and rated as it plays. The
CSV records which was which.

**On pairing — a deliberate deviation from the brief.** The brief asks for a
paired test. These trials cannot be paired: each trial draws its own random
target angle, so there is no matched Original/Sharp pair to difference. Running
a paired test on arbitrarily ordered trials would be wrong. The tests above are
the correct *unpaired* trial-level comparison within a session. The genuine
within-subject paired analysis works on one mean per participant per condition
and needs several participants — which a single-participant prototype cannot
supply. The app prints this caveat with every comparison.

Target angles are drawn **stratified**: one uniform sample from each of thirty
6°-wide bins across −90…+90, then shuffled — uniform coverage without the
clustering that 30 plain uniform draws produce. A measured schedule had exactly
5 targets in each 30° sector and a largest adjacent gap of 10.5°.

The target angle is **hidden by default**; the debug panel (**D**) is the only
thing that reveals it.

## 11a. Geometry test

    ./build/Prototype2.app/Contents/MacOS/Prototype2 --geometry-test

A deterministic end-to-end check of the reference frame. It drives the real code
path — synthetic device yaw → `deviceYaw` → calibrated-neutral subtraction →
smoothing → `setListenerYaw` → the live AVAudioEngine nodes — and reads the
answers back **off the audio engine**, not from a parallel calculation. Two
details let it catch the bugs that matter:

- the calibrated neutral sits at a **non-zero raw device yaw** (−137°), so any
  code that forgets to subtract it fails immediately;
- the head is deliberately **parked off-centre (+30°) before the trial starts**,
  so any code that re-zeroes the frame at trial onset fails immediately.

It asserts the full ±45° tables at 15° steps, that the source's `AVAudio3DPoint`
never moves while the listener rotates, and that 60,000 generated targets all
fall within ±90°.

When run against the pre-fix code it failed all 12 relative-angle rows with an
offset exactly equal to the parked head position. After the fix all rows pass.

## 11. Validation performed

`./verify.sh` (offline, measured, exits non-zero on failure) checks:

- angle wrapping, `delta` across the ±180° seam, unwrap continuity;
- the full brief §12 table in both signs, plus ±135° cases;
- `+X` = right and `−Z` = forward in the emitted source positions;
- HRTFHQ is applicable *and* in force on the source bus;
- a real ITD exists (542 µs at 60°) and amplitude panning produces none;
- centre renders balanced (−0.51 dB, 0 µs); ±90° lateralise to the right ear;
- ITD is monotonic across −90…+90°;
- **world-fixedness**: for every (target, head) pair, the rotated render is
  compared against a static render at the expected relative angle, and matches
  to within 0.00 dB and 0 µs;
- overshooting past the target moves the source to the *other* side — the check
  that catches a listener-yaw sign error;
- **stimuli**: Sound A's RMS is still exactly 0.10 (the baseline is intact); the
  two are loudness-matched to within 0.01 LU; neither clips; Sharp has 93% less
  energy below 300 Hz and 76% more in 2–8 kHz; Sharp's envelope periodicity is
  at white-noise level; Sharp's crest factor exceeds Original's by >3×;
- **both stimuli** independently pass the HRTF and world-fixed geometry checks —
  real ITD (500 µs for Sharp, 542 µs for Original at +60°), correct
  lateralisation, centring when faced, and the rotated-vs-static match;
- **randomisation**: 50.6% over 20 000 draws; a Wald–Wolfowitz runs test
  (z = −0.77) confirms the sequence is not predictable; fixed modes never vary;
  different seeds give different sequences;
- **statistics**: medians and within-±N percentages against hand-checked values,
  angular wrapping surviving the whole pipeline, Welch's t and Mann-Whitney
  against known pairs, the t and normal tails against table values (0.0250),
  Cohen's d against a known pair, and the small-sample guard actually refusing.

`--simulate` runs a virtual participant through all 30 trials headlessly, in any
mode (`--mode original|sharp|random`). A full run confirmed: sign auto-detection works (errors stayed small and unbiased),
25.0 Hz trajectory sampling with all 30 trials covered, ISO timestamps agreeing
with the high-resolution response times to within ~1 ms, and 30 trials running
sequentially without restarting the app.

Diagnostics separate failure classes: the **D** panel shows head tracking
(samples, raw yaw/pitch/roll, authorization, sign, staleness), the coordinate
transform (neutral, target, relative angle, listener orientation, source XYZ),
audio (HRTF active, applicable algorithms), trial logic (phase, sample counts)
and logging (output path).

## 12. Known limitations

- **Motion sample rate is 50 Hz** (measured) and Apple exposes no way to raise
  it. The logged trajectory therefore has 20 ms resolution, and the yaw recorded
  at the SPACE press can be up to 20 ms stale — at a brisk 60°/s head turn that
  is ~1.2° of uncertainty. The response *time* itself is precise (taken from
  `NSEvent.timestamp`, the same clock as the motion timestamps).
- **Yaw drifts.** No magnetometer in AirPods, so heading is gyro-integrated.
  Mitigated by re-zeroing every trial, but a very long trial will still drift.
- **Sound B is a hypothesis, not a known improvement.** The whole point of
  Random A/B is to let the data decide. Nothing in the implementation is tuned
  to favour it, and the analysis code applies the same treatment to both.
- **Apple's HRTF is a fixed, generic set** with no individualisation and no
  published measurements. It is also slightly asymmetric (−729 µs at −90° vs
  +750 µs at +90°), which will show up as a small left/right bias in results.
- **Front/back and elevation are not modelled** — by design, the task is yaw-only
  and targets are confined to the frontal ±90°.
- **Ad-hoc signing re-triggers the motion prompt** after each rebuild unless
  `CODESIGN_ID` is set to a stable identity.
- **Latency is not instrumented.** The audio path is one process with no
  resampling, but end-to-end motion-to-sound latency (AirPods IMU transmission +
  25 Hz sampling + AVAudioEngine buffering + Bluetooth audio) has not been
  measured and is likely in the 100–200 ms range, dominated by Bluetooth. This
  matters for the *feel* of the task, not for the recorded angles.
- **`AVAudioEnvironmentNode.listenerHeadTrackingEnabled` is deliberately off.**
  Enabling it would apply Apple's own AirPods head tracking on top of ours and
  double-count every rotation.
- The simulator is a development tool only; simulated trials are written with
  `tracking_active = 0` so they can never be mistaken for real data.

### Limitations specific to the A/B comparison

- **One participant, one session, cannot establish anything.** Practice, fatigue,
  headphone-fit drift and attention all vary across a block and none of them are
  controlled. A 30-trial Random A/B block can show a *promising* effect; it
  cannot show a real one. This is stated in the app's own output.
- **Trials are unpaired** (see §10a). The single-session analysis is necessarily
  the weaker unpaired form.
- **Independent coin flips mean unequal n.** A 30-trial block will rarely be
  exactly 15/15; expect roughly 15 ± 3 per condition, which is near the floor
  for the tests to say anything. Several blocks are better than one.
- **The stimuli differ in more than one way at once** — spectrum *and* temporal
  structure both changed. If Sharp wins, this design cannot say which change was
  responsible. That is the right trade for a first screening test, but a
  follow-up should vary one at a time.
- **Loudness matching is objective, not perceptual.** BS.1770 is a broadcast
  loudness standard, not a model of how a listener judges these two very
  different textures. They are matched to within 0.01 LU by that measure; a
  listener may still judge one slightly louder.
- **Sound B may be less pleasant over long sessions.** It is denser and brighter
  than white noise. Comfort was a design constraint (10 kHz low-pass, no
  periodicity, loudness matched) but it is a subjective judgement — worth asking
  the participant about after a block.
