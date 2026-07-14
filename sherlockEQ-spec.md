# SherlockEQ — Specification
**Name:** SherlockEQ
**Type:** macOS hybrid app — menu bar popover + full main window
**Target OS:** macOS 14.6 (Sonoma) and later
**Language:** Swift 5 / SwiftUI (SwiftUI default actor isolation = MainActor)
**Build tool:** Xcode 16+
**Audio:** Core Audio Taps (CATap) + AVAudioEngine + manual biquad cascades (per-ear)
**Auto-updates:** Sparkle 2.x (EdDSA-signed appcast at `https://snxt.ai/appcast.xml`)

---

## 1. Positioning

SherlockEQ is a **system-wide audio personalization tool** for macOS users whose hearing
doesn't match factory defaults — people with mild-to-moderate hearing loss, tinnitus,
asymmetric hearing, or simply ears that have changed over time.

It is **not** a health app, hearing aid, or medical device. It makes no diagnostic
claims. It is a precision audio tool in the same spirit as a color-calibrated display
profile: correcting the signal so the experience matches what was intended.

The primary audience is **prosumer** — podcast hosts, podcast editors, audiobook
listeners, remote workers on long calls, casual music listeners who care about fidelity.
They want the best possible hearing experience from their Mac. They are not record
producers. They do not need channel strips, busses, or gain staging.

---

## 2. Target User Profiles

**The Tinnitus Listener**
Has a persistent ringing at a specific frequency. Fatigues easily during long listening
sessions. Wants to reduce the mental load of filtering out the ringing while keeping
music and voice sounding natural.

**The Gradual Loss Listener**
High-frequency loss from age or noise exposure. Notices consonants and sibilance going
missing in speech. Wears hearing aids sometimes, but not always. Wants their Mac to
sound the way it used to.

**The Asymmetric Listener**
One ear significantly different from the other. Stereo imaging sounds off. Panning in
music feels wrong. Needs independent left/right channel correction and per-ear notch
control for asymmetric tinnitus.

**The Podcast Prosumer**
Hosts or edits a personal or semi-professional podcast. Monitors audio during editing
and recording. Needs confidence that what they're hearing accurately reflects what
listeners hear. Uses Reference Mode to A/B their mix against their hearing profile.

---

## 3. Core Principles

- **Do no harm.** Every boost has a ceiling. The app surfaces estimated listening dose
  and warns before safe limits are reached. Users should feel confident they are
  protecting, not damaging, their remaining hearing.
- **Transparency.** The app always shows what it is doing to the signal. Reference mode
  bypasses processing instantly for comparison.
- **Not clinical.** No medical language. No diagnosis. No treatment claims. Audiogram
  input is a convenience, not a prescription.
- **Two speeds.** The popover handles the 5-second interactions. The main window handles
  everything that deserves a chair. Neither tries to do the other's job.
- **Prosumer ceiling.** Full parametric control is available but not the default. The
  default experience is guided and friendly.
- **Errors route through `NoticeCenter`.** Every user-facing warning or error surfaces
  via the central notice banner (visible in both the popover and the main window's
  detail area), not via ad-hoc alerts or Debug-only state.

---

## 4. UI Surface Map

SherlockEQ has two primary surfaces — a menu-bar popover for quick operation, and a
main window for configuration — plus a persistent right-hand monitor sidebar inside the
main window.

### Menu Bar Popover (380pt wide)
The popover is for **operating** SherlockEQ, not configuring it. It dismisses when you
click away. Implemented as a SwiftUI `MenuBarExtra` with `.menuBarExtraStyle(.window)`.

What belongs here (top → bottom):
- Header: app icon + name, read-only current output device label, "Open SherlockEQ"
  arrow button (opens main window via `AppDelegate.showMainWindow`)
- Notice banner (shared `NoticeCenter` — also rendered in the main window)
- Session dose bar (percent + remaining minutes)
- Stereo level strip (live L/R peak meters, A-weighted dBA via calibration offset)
- Master gain slider (`-60…+12 dB`) with recenter button
- Balance slider (`-1…+1`, per active profile) with recenter button
- Profile picker row
- Compensation strength slider
- Tinnitus notch on/off + frequency label
- Reference Mode button (prominent)

What does **not** belong here:
- Audiogram entry
- Parametric EQ canvas
- Spectrum analyzer
- Profile creation or editing
- Settings
- Output device picker (the popover shows the current device as a read-only label;
  device routing follows the macOS default output. Profile→device auto-switching is
  configured per profile in Profile Detail.)

### Main Window (default 1480 × 880pt, minimum 1400 × 740pt)
Opened deliberately from the popover. Appears in the Dock and CMD+Tab while open.
Uses `NavigationSplitView` with a left sidebar and a persistent right monitor sidebar
(220pt) toggleable from the toolbar.

What belongs here:
- All profile management (create, duplicate, delete, reorder, import, export)
- Audiogram entry (interactive chart + numeric fields)
- Equalizer (Simple / Speech / Advanced / Expert — the active profile commits to one
  mode; mode picker lives on Profile Detail)
- Tinnitus Notch (Tone Finder + notch controls, consolidated)
- Safe Listening detail and history
- All Settings
- Debug diagnostics

### Right-Hand Monitor Sidebar (220pt, toggleable)
Persistent across every main-window section so the user keeps level/dose awareness
while editing EQ, browsing profiles, calibrating, etc. Contents:
1. Output level VU — vertical L/R peak meter. Triple-tap the header to swap
   between the Digital and Analog VU displays (the analog dial is the
   nostalgic easter egg shared with the Analog Control Unit).
2. Master gain slider (`-60…+12 dB`).
3. Balance slider (per active profile, `-1…+1`) with recenter button.
4. Dose mini-bar — today's NIOSH dose as a thin green/amber/red capsule.

Visibility persisted via `@AppStorage("sherlockeq.monitorSidebarVisible")`. Defaults
to visible so first-launch users discover it.

### Activation Policy
- Window closed → `NSApp.setActivationPolicy(.accessory)` — menu bar only, no Dock
  icon, not in CMD+Tab. Controlled by `preferences.hideFromDockEnabled` (default on).
- Window open → `NSApp.setActivationPolicy(.regular)` — Dock icon appears, CMD+Tab
  works.
- The flip is sequenced manually in `AppDelegate.showMainWindow`: policy change →
  short runloop pump (~10ms) → `NSRunningApplication.current.activate(options:
  .activateAllWindows)` → `makeKeyAndOrderFront`. This works around the
  `NSApp.activate(ignoringOtherApps:)` deprecation on macOS 14+ where the menu bar
  silently stays greyed out.
- `applicationShouldTerminateAfterLastWindowClosed` returns `false` — closing the
  window doesn't quit.

### Multi-Instance Guard
`applicationWillFinishLaunching` checks for another running instance by bundle ID;
if one is found, it activates that instance and calls `NSApp.terminate(nil)`. Two
SherlockEQ binaries would each install a CATap that captures the other's output and
loop.

---

## 5. Feature Set

### 5.1 Hearing Profile System (Core)

A **Hearing Profile** is the central data object. Users can create and name multiple
profiles — one per output device, per context, or per activity.

Each profile contains (see `HearingProfile.swift`):
- `id: UUID`, `name: String`, `symbol: String` (SF Symbol)
- `linkedDeviceUID: String?` — optional auto-switch target
- `leftEar: EarProfile`, `rightEar: EarProfile` (each carries audiogram thresholds +
  derived EQ bands)
- `leftNotch: TinnitusNotch`, `rightNotch: TinnitusNotch` — per-ear notches
- `separateNotch: Bool` — when false, the notch UI writes both ears in lockstep;
  when true, the user can dial in different notches per ear
- `globalTrimDB: Double` — `-12…+12`, guards against post-boost clipping
- `balance: Double` — `-1` (full L) ... `0` (center) ... `+1` (full R)
- `autoEQCurveURL: URL?` (legacy decode-only), `autoEQName: String?`,
  `autoEQBands: [EQBand]?`, `autoEQPreampDB: Double?` — parsed AutoEQ correction
- `safeListeningCeilingDB: Double` — user-set, default 85.0
- `compensationFactor: Double` — `0.25…1.0`, audiogram→EQ strength
- `separateChannels: Bool` — toggles per-ear UI for the Simple/Advanced/Expert EQ
  surfaces (default false: single-column UI; symmetric-hearing users keep it off)
- `eqMode: EQMode` — `.simple`, `.speech`, `.advanced`, `.expert`. The four modes
  are storage views onto the same band array, not stackable layers — the profile
  commits to one mental model. Switching is non-destructive. New profiles default
  to `.simple`; legacy decode defaults to `.expert`.
- `isBuiltIn: Bool` — marks one of the four shipped factory listening presets
  (Voice Clarity, Music Balanced, Gentle Listening, Presence Boost). No longer a
  lock: factory presets are editable in place. The flag only enables a per-profile
  "Reset to Factory Default" and inclusion in "Restore Factory Presets". Editing a
  factory preset can also be branched into a separate user copy via Duplicate.
- `presetDescription: String?`, `presetTags: [String]` — user-facing card copy for
  factory presets (nil/empty for user profiles). `decodeIfPresent` for back-compat.
- `createdAt: Date`, `modifiedAt: Date`

Custom `Codable` decoder preserves backwards compatibility: pre-balance, pre-isBuiltIn
profiles still load, and the legacy single `notch` field mirrors onto both per-ear
notches.

Profiles are stored as one `<UUID>.json` file each under
`~/Library/Application Support/SherlockEQ/profiles/` (overridable via
`UserDefaults["sherlockeq.profilesDirectory"]`; Settings exposes a folder picker).
JSON is pretty-printed with sorted keys + ISO-8601 dates.

Writes route through `ProfileStore.save(_:)`, which registers undo on the window's
`UndoManager` and coalesces rapid saves of the same profile within a 500ms window
into one undo step (so a slider drag reverts as one Cmd-Z).

---

### 5.2 Audiogram Import

The user enters their audiogram data — the numbers from a printed or digital report
from their audiologist. Lives in the main window's Audiogram section.

**Standard audiogram frequencies (Hz):**
`250, 500, 1000, 2000, 3000, 4000, 6000, 8000` (`AudiogramPoint.standardFrequencies`)

**Entry method:** interactive chart with draggable threshold points per ear, plus
numeric fields alongside. Values entered in **dB HL** (hearing level, as reported
on audiograms). Left/right tab on the same screen.

**Conversion to EQ** (`AudiogramConversion.bands(for:compensationFactor:)`):
- > **Implemented (updated after this spec):** the linear half-gain formula below
  > was the original design. Shipping code uses the **NAL-R** prescription
  > (Byrne & Dillon 1986): `REIG(f) = X + 0.31·HTL(f) + k(f)`, with
  > `X = 0.05·(HTL₅₀₀ + HTL₁₀₀₀ + HTL₂₀₀₀)`. `compensationFactor` is now an overall
  > strength multiplier on the whole prescription (not the gain fraction). The
  > ceiling, disable-threshold, band count, and slider below still hold.
- `gain_at_freq = threshold_dBHL × compensation_factor` *(original design; superseded by NAL-R)*
- Default `compensationFactor` = 0.5; range `0.25…1.0`
- Hard ceiling: no single band boosted more than **+20 dB** regardless of loss
  (`AudiogramConversion.perBandCeilingDB`)
- Bands disabled when pre-compensation loss is < 5 dB HL (no audible boost needed)
- One band emitted per audiogram point (8 bands per ear). Cubic-spline-derived
  intermediate bands are not implemented — the algorithm signature can absorb that
  later without API churn.
- User adjusts `compensationFactor` via the "Compensation Strength" slider in both
  the popover (quick) and the main window (in context with the EQ curve preview).

**Caveat messaging (non-clinical):**
> "For losses above 40 dB, an EQ alone may not fully restore clarity — a hearing
> professional can discuss additional options. SherlockEQ is not a substitute for hearing aids."

**Per-ear independence:** left and right ears are configured separately. The audio
engine processes L and R as independent mono streams via per-ear `BiquadCascade`
inside the source-node render block (see §7.1).

---

### 5.3 Tinnitus Notch Filter

A narrow frequency cut applied at the user's tinnitus pitch. Per-ear by design — the
profile carries `leftNotch` and `rightNotch` independently, with a `separateNotch`
toggle that controls whether the UI exposes two panels or links them.

SherlockEQ makes no therapeutic claims. The notch is presented as a way to reduce
the presence of frequencies that are already mentally fatiguing to the user.

**Popover:** linked notch on/off toggle + frequency label.

**Main window — Tinnitus Notch view:** full controls. Frequency (1000–16000 Hz),
depth (`-3` to `-15` dB), width (Narrow / Medium / Wide → Q = 8.0 / 4.0 / 2.0,
see `NotchWidth.qValue`). When `separateNotch` is on, the screen shows two stacked
notch panels (Left ear, Right ear). The notch is rendered as a labeled notch on the
Expert EQ curve.

The Tone Finder and notch controls live on the same view (sidebar entry "Tinnitus
Notch") so the user reads them as one task — identify the pitch, then dial in the
notch.

---

### 5.4 Safe Listening Monitor

SherlockEQ estimates output loudness using FFT-derived RMS on the post-EQ audio
stream (A-weighted per-bin), then converts dBFS to dBA via the user's calibration
offset (`calibrationOffsetDBA`, default 100, persisted). Dose accumulates against
NIOSH's equal-energy 3 dB exchange rule.

**Volume-aware calibration** (see `volume-aware-dose.md`): CATap captures audio
*upstream* of the hardware volume control, so a fixed offset is only correct at
the volume the user calibrated at. Setting the calibration therefore records a
**volume anchor** — the system output volume (dB) and device UID at that moment
(`CalibrationVolumeAnchor`, persisted) — and at runtime the dose pipeline uses
`effectiveCalibrationOffsetDBA = base + (currentVolumeDB − anchorVolumeDB)`,
tracked live via an always-on `SystemVolumeController` instance owned by
`AudioState`. A muted output contributes ~zero dose. Every unreadable condition
(device with no volume property, device changed since calibration, legacy
install with no anchor) degrades to delta = 0 — the legacy fixed-offset
behavior — and the Safe Listening screen shows a status line saying which state
applies. Meter zone boundaries and the canvas safety overlay consume the
effective offset too, so every at-ear-level surface agrees.

NIOSH constants (`SafeListeningTracker`):
- `nioshReferenceLevelDBA = 85`
- `nioshReferenceDuration = 28800 s` (8 hours)
- `nioshExchangeRateDB = 3`
- Permissible duration at any dBA: `28800 / 2^((dBA - 85) / 3)`

| Level (dBA) | Safe Duration |
|-------------|--------------|
| ≤ 70        | Effectively unlimited |
| 80          | ~8 hours      |
| 85          | ~2.5 hours    |
| 88          | ~1.25 hours   |
| 91          | ~37 minutes   |
| 94          | ~18 minutes   |
| 100         | ~4 minutes    |

**Popover:** compact dose bar (green → amber → red), remaining-time label.

**Main window — Safe Listening view:** full detail — current level estimate, session
history, ceiling configuration, notification preferences, SPL-calibration workflow.

**Behavior:**
- Dose accumulates at all levels (NIOSH self-regulates — permissible duration at
  low dBA is enormous, contribution is near zero). A `quietThresholdDBA` (default
  50) only gates the "remaining minutes" display and the sustained-quiet reset.
- At 80% of daily dose: amber indicator in popover + menu bar icon tint, optional
  system notification (gated by `notificationsEnabled` and the user's macOS
  notification authorization).
- At 100%: red indicator, system notification: "You've reached your safe listening
  limit for today. Consider taking a break."
- One-shot per-day flags (`didCrossAmberToday`, `didCrossRedToday`) prevent
  re-firing the same notification.
- Dose resets at the calendar-day boundary (midnight rollover) or after a sustained
  quiet period (default 2h, `quietResetDuration`).
- "Remaining minutes" is computed off a 60s power-domain rolling average and
  republished at most once per minute so the readout doesn't twitch.

**Important framing:** this is an *estimate* based on digital signal level converted
via a user-set calibration offset. System-volume changes since calibration are
tracked into the estimate automatically (when the output device exposes its
volume); actual SPL at the ear still depends on headphone type and fit. The
calibration workflow plays a 1 kHz / −12 dBFS reference tone so the user can
match it to a known SPL with an external meter.

---

### 5.5 Reference Mode

A momentary bypass for A/B comparison. Implemented as a single `setBypassed(true)`
call on both per-ear `BiquadCascade` nodes — the entire EQ stack (AutoEQ + profile
bands + notch + trim) drops out at once. No graph reconfiguration, no audio dropout.

**Popover:** prominent Reference Mode button.
**Main window:** Reference button also present in the Expert EQ toolbar.
**Menu bar:** Audio → Toggle Reference Mode (⌘B local).
**Global shortcut:** ⌘⇧B when `preferences.globalReferenceShortcutEnabled` is on
(registered via Carbon `RegisterEventHotKey` in `GlobalHotKey`).
**Distinct from `eqMasterEnabled`:** reference mode is the transient A/B toggle;
`eqMasterEnabled` is the user's durable on/off (persisted).

---

### 5.6 Device Profiles & Auto-Switching

Any profile can be linked to a specific output device by UID. When that device
becomes the default output, `AudioState.autoSwitchProfileIfLinked()` activates
its profile.

**Popover:** the header shows the current output device name as a read-only label.
**Main window — Profile Detail:** picker for the linked device UID.
**Settings:** device auto-switching is a profile-level concern; there is no separate
device-map manager.

---

### 5.7 AutoEQ Integration

Import headphone correction curves from the AutoEQ project. The correction is parsed
into `EQBand` values (`AutoEQParser`) and pushed onto the per-ear `BiquadCascade`
*upstream* of the profile's own bands, with the AutoEQ preamp folded into the
cascade's gain. Headphone-correction toggle (`eqChain.autoEQEnabled`) is independent
of the profile-EQ toggle (`eqChain.manualEQEnabled`).

```
Per-ear cascade: [AutoEQ correction] → [Profile EQ bands] → [Tinnitus notch] → [Global trim]
```

The integration has more surface than a single file picker:
- **`AutoEQParser`** — parses AutoEQ `.txt` parametric files (preamp + per-band
  freq/gain/Q).
- **`AutoEQLibrary`** — manages a user-selected library folder of `.txt` files.
  The Profile-Detail picker offers every `.txt` in this folder.
- **`AutoEQRemoteService`** — fetches the AutoEQ catalog
  (`https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/...`).
  Caches index + profiles under `Application Support/SherlockEQ`. Refreshes the
  index weekly; backs off 5 minutes after a 403 rate-limit. Errors surface as a
  typed `AutoEQFetchError`.
- **`AutoEQRemote`** — Phase-1 fetcher with rate-limit + offline classification.
- **`AutoEQSavedProfilesStore`** — persistent store of saved AutoEQ corrections the
  user keeps across profile edits.
- **`AutoEQConflictDetector`** — warns when a loaded correction conflicts with
  manually-dialed bands.
- **`AutoEQSearchView`** — UI surface inside Profiles for searching the remote
  catalog and importing a correction into the active profile.

User-selected library folder is stored in `AutoEQPreferences.libraryFolder`
(UserDefaults; the app runs without sandbox, so no security-scoped bookmarks
needed).

---

### 5.8 Factory Listening Presets

Four shipped **listening-comfort presets** built on the existing 10-band Advanced EQ
(`HearingProfile.factoryProfiles`). These are tone/comfort presets — **not** medical
hearing correction; copy never implies treating hearing loss, tinnitus, or any
condition. Each has a stable id, `eqMode: .advanced`, identical L/R bands, an output
trim folded into `globalTrimDB`, `isBuiltIn: true`, and a `presetDescription` +
`presetTags` for its card. Canonical UI order: Voice Clarity, Music Balanced, Gentle
Listening, Presence Boost. The cold default (and onboarding default) is **Music
Balanced**.

Gains per factory-preset center (31.5 / 63 / 125 / 250 / 500 / 1k / 2k / 4k /
8k / 16k Hz — the v1 authoring grid; the Advanced *surface* is now the 12-band
audiometric grid with 3 kHz and 6 kHz added, where these presets read 0 until
the Phase-3 §3 re-voicing):

| Preset | Bands (dB) | Output trim |
|---|---|---|
| Voice Clarity | −4, −3, −2, −1, 0, +1, +2, +2.5, +0.5, −1 | −2 dB |
| Music Balanced | +0.5, +1, +0.5, −0.5, 0, 0, +0.5, +1, 0, −0.5 | −1 dB |
| Gentle Listening | 0, 0, +0.5, +0.5, 0, 0, −0.5, −1.5, −2.5, −3 | 0 dB |
| Presence Boost | −1, −1, −1, −0.5, 0, +0.5, +1.5, +2, +0.5, 0 | −2 dB |

**Factory lifecycle.** `ProfileStore.reconcileFactoryPresets()` (version-gated on
`sherlockeq.factoryPresetsVersion`) installs the four on first launch and, on upgrade,
removes the legacy `Default` / `Voice Clarity` built-ins and installs the four. A
deleted preset is **not** silently re-added on later launches. `restoreFactoryPresets()`
(Profiles toolbar) recreates/resets all four; `resetProfileToFactory(_:)` reverts one.
The limiter stays the existing global setting — no per-profile limiter state. Transitions
remain instant hard-swaps (click-free by the cascade's state-zeroing + denormal flush);
no ramping was added.

Separately, the **Speech EQ mode** (`EQMode.speech`) is a 6-band slider surface
(60 Hz low-shelf, 200 / 800 / 2500 / 6000 Hz parametric, 12 kHz high-shelf) so users
can dial in a voice-tuned EQ themselves without using the preset.

---

### 5.9 Parametric EQ (Expert View)

The full-control surface. Reached by setting the active profile's `eqMode` to
`.expert` (mode picker lives on Profile Detail). Rendered by `ExpertEQView` via
`ParametricCanvasView`.

- Interactive frequency response canvas: log-scaled x-axis (20 Hz – 20 kHz),
  ±24 dB y-axis
- Draggable nodes: x = frequency, y = gain
- Filter types per band (`EQFilterType`): parametric, lowShelf, highShelf, notch,
  bandPass, lowPass, highPass
- Composite biquad curve computed via `BiquadCoefficients` / `BiquadResponse`
- Spectrum underlay drawn at the bottom 1/3, log-binned from
  `SpectrumAnalyzer.logSpectrumDB` (vDSP discrete Fourier transform). Pre-EQ
  spectrum optionally overlaid as a thin cyan outline.
- One visualisation: the live spectrum (line + peak-hold + pre-EQ outline).
  The former `.octaveBars` / `.spectrogram` modes, the peak-callout chips, and
  the lens presets were removed in the scope-reduction pass (2026-07) — the
  layer chips (Output / Input / Result / EQ / Correction / Safety / Dynamics)
  are the remaining, individually toggleable overlays.
- L and R curves displayed simultaneously (different colors via
  `AppPreferences.leftEarColor` / `.rightEarColor`), with a Link L+R toggle to edit
  one or both ears
- Audiogram-derived target bands rendered as a dashed ghost behind the active curve
  so the user can see how far their manual tuning has drifted
- Tinnitus notch rendered as a labeled notch on the curve; edits route through
  `NotchControlView`, not the canvas, so the dedicated freq/depth/width inputs stay
  authoritative

---

### 5.10 Tone Finder

Lives inside the Tinnitus Notch view in the main window — Tone Finder and notch
controls share one screen so the user reads identify-then-dial as one task.

- Large frequency readout (Hz)
- Sine-tone generator (`SineToneGenerator`) routed directly into `mainMixerNode`
  upstream of master gain, bypassing per-ear EQ so the reference pitch isn't
  coloured by the profile
- Drag/swipe target to sweep frequency (log scale, **1 kHz – 16 kHz**)
- Fine-tune stepper (±1 Hz)
- Volume row
- "Set as notch frequency" action — writes into the active profile's notch and
  flips it on. With `separateNotch` on, the user picks Left / Right / Both.
- Non-clinical copy: "Drag to find the pitch closest to your ringing."

---

## 6. What Is Explicitly Out of Scope

- Per-application volume routing (would require a virtual driver)
- Recording / capture to file
- Virtual output devices
- MIDI or hardware control surfaces
- iOS / iPadOS companion
- Multichannel / surround audio (stereo only)
- Any clinical diagnostic feature
- Onboarding wizard (not currently implemented — see §8.4)

---

## 7. Technical Architecture

### 7.1 Audio Signal Path

```
┌────────────────────────────────────────────────────────────────────────┐
│ CATapEngine                                                            │
│                                                                        │
│  CATap (default output, all processes)                                 │
│   │                                                                    │
│   ├──► leftSourceNode  (mono L; render block runs leftEQCascade)       │
│   └──► rightSourceNode (mono R; render block runs rightEQCascade)      │
│                                                                        │
│  Each cascade carries, in order:                                       │
│    AutoEQ correction → Profile EQ bands → Tinnitus notch → Trim        │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
                              │ (stereo with one channel zeroed each)
┌────────────────────────────────────────────────────────────────────────┐
│ SherlockEQAudioEngine (AVAudioEngine)                                  │
│                                                                        │
│  leftSourceNode  ──► leftBalanceMixer  ─┐                              │
│                                          ├──► sumMixer ──► AUPeakLimiter
│  rightSourceNode ──► rightBalanceMixer ─┘                          │   │
│                                                                    ▼   │
│                                              masterGainStage (AVAudioUnitEQ
│                                              with 1 bypassed band, used as
│                                              a gain-only stage; -60…+12 dB)
│                                                          │             │
│                                                          ▼             │
│                                              mainMixerNode ──► outputNode
│                                                          │             │
│                                              SpectrumTap (vDSP FFT)    │
│                                                          ▼             │
│                                              SpectrumAnalyzer →        │
│                                              SafeListeningTracker      │
│                                                                        │
│  toneSourceNode (Tone Finder sine) ──► mainMixerNode (bypasses EQ)     │
└────────────────────────────────────────────────────────────────────────┘
```

Key implementation notes:

- **Per-ear EQ runs inside the source-node render block** as a manual
  `BiquadCascade` per ear, owned by `CATapEngine`. This replaces an earlier
  AVAudioUnitEQ-per-ear graph layout that introduced cross-channel content
  (~−50 dB) under mono-on-one-channel input and ~45 dB of leak at extreme balance
  pans. Running the filter on a single mono Float buffer per render block keeps
  L and R signal paths physically separate.
- **Balance** is realized via `AVAudioMixerNode.outputVolume` (linear, from the
  `AVAudioMixing` protocol) on per-ear balance mixers between the source nodes and
  the sumMixer — *not* via `AVAudioUnitEQ.globalGain`, which leaked at extreme
  attenuations.
- **Master gain** is realized via a 1-band-bypassed `AVAudioUnitEQ`'s `globalGain`
  (range `-96…+24 dB`, clamped by SherlockEQ to `-60…+12 dB`) because
  `mainMixerNode.outputVolume` silently no-ops on this graph.
- **Limiter** is Apple's `AUPeakLimiter` (`kAudioUnitSubType_PeakLimiter`) right
  before master gain so band sums that overshoot get brick-walled cleanly.
- **Sample-rate handling:** the source-node format is stamped at the output device's
  nominal rate (the rate the aggregate's drift-compensated IOProc delivers), so the
  graph is uniform end-to-end with no SRC node. If the rates ever disagree on
  rebuild the engine refuses to start and surfaces a typed error rather than
  silently producing wrong-rate audio.
- **Tinnitus notch** lives inside each cascade — not as a separate node — so it
  rides the same bypass and renders as a labeled notch on the Expert curve.
- **Reference Mode** calls `setBypassed(true)` on both cascades simultaneously.
  Glitch-free, no graph reconfiguration.
- **Tone Finder sine** is attached directly to `mainMixerNode`, bypassing the
  per-ear EQ so the reference pitch isn't coloured.
- **Spectrum tap** is installed on `mainMixerNode` (not on `masterGainStage`) so
  the meter reflects what the listener actually hears — `mainMixerNode` scrubs
  residual cross-channel content that's audible in upstream nodes but inaudible
  at the speakers.
- **AVAudioEngine configuration changes** (Bluetooth route swap, sample-rate
  renegotiation) post `.AVAudioEngineConfigurationChange`; `SherlockEQAudioEngine`
  hops the callback to `@MainActor` and asks `AudioState` to rebuild the graph
  so the user doesn't end up in silence after a route change.

---

### 7.2 CATapEngine

`@MainActor final class CATapEngine: ObservableObject` (macOS 14.6+).

```swift
enum State: Equatable {
    case idle
    case awaitingPermission
    case permissionDenied
    case starting
    case running
    case failed(String)
}

@Published private(set) var state: State
@Published private(set) var permissionGranted: Bool
@Published private(set) var currentOutputDeviceID: AudioDeviceID
@Published private(set) var currentOutputDeviceName: String

let leftEQCascade: BiquadCascade
let rightEQCascade: BiquadCascade
private(set) var leftSourceNode:  AVAudioSourceNode?
private(set) var rightSourceNode: AVAudioSourceNode?
private(set) var sourceFormat: AVAudioFormat?
private(set) var tapFormat: AVAudioFormat?

var onOutputDeviceChanged: ((AudioDeviceID) -> Void)?

func requestPermissionAndStart() async { ... }
func stop() { ... }
```

- Tap targets all processes on the default output device. The current process's
  PID is excluded from the tap so SherlockEQ's own output doesn't feed back into
  its input.
- A device-change listener on `kAudioHardwarePropertyDefaultOutputDevice` tears down
  and restarts the tap cleanly, then fires `onOutputDeviceChanged` which runs the
  profile auto-switch logic.
- A pre-EQ spectrum ingest slot (`PreSpectrumIngestSlot`, lock-protected) lets
  `SpectrumAnalyzer.preSpectrum` see the raw input for the Expert canvas's pre-EQ
  outline without competing for the cascades' state.
- Permission: requests via `kTCCServiceAudioCapture` (the "System Audio Recording"
  TCC bucket on macOS 15+; grouped under Screen Recording in the 14.x UI). On
  denial, posts a `NoticeCenter` warning with an Open System Settings affordance.

---

### 7.3 AudioState (ObservableObject)

`@MainActor final class AudioState: ObservableObject`. The single source of truth
for the audio pipeline; injected at the top of both popover and window hierarchies
via `@EnvironmentObject`. Composes several focused sub-objects:

| Sub-object | Role |
|------------|------|
| `tap: CATapEngine` | CATap + per-ear source nodes + cascades |
| `audio: SherlockEQAudioEngine` | AVAudioEngine graph, balance, limiter, master gain |
| `spectrum: SpectrumAnalyzer` | Post-EQ vDSP FFT, A-weighting, dose feed |
| `preSpectrum: SpectrumAnalyzer` | Pre-EQ FFT for Expert canvas overlay |
| `stereoMonitor: StereoMonitor` | L/R peak meters for Monitor Sidebar + popover |
| `safeListening: SafeListeningTracker` | NIOSH dose accumulator |
| `eqChain: EQChainState` | referenceMode, testCurveEnabled, testToneEnabled, calibrationToneEnabled, eqMasterEnabled, autoEQEnabled, notchFilterEnabled, manualEQEnabled, hasShownNotchOffReminder |
| `engineParameters: EngineParameters` | masterGainDB, limiter attack/decay/preGain |
| `preferences: AppPreferences` | leftEarColor, rightEarColor, hideFromDockEnabled, launchAtLoginEnabled, globalReferenceShortcutEnabled |
| `autoEQPreferences: AutoEQPreferences` | libraryFolder |
| `noticeCenter: NoticeCenter` | shared user-visible notice banner state |

AudioState exposes proxy bindings for the most-used sub-object fields
(`referenceMode`, `masterGainDB`, `eqMasterEnabled`, `leftEarColor`, etc.) so existing
view code that reads through AudioState keeps working; new code should depend on
the sub-objects directly.

Other AudioState surface:
- `@Published var activeProfileID: UUID?` — persisted to UserDefaults
  (`sherlockeq.activeProfileID`)
- `@Published var sessionDosePercent: Double` and `remainingMinutes: Double?` —
  throttled 1 Hz mirrors of `safeListening` state for views that re-render on every
  AudioState tick (popover, MonitorSidebar). Faster-updating consumers
  (SafeListeningView, MenuBarIcon, DebugView) read `safeListening.sessionDose` /
  `.remainingMinutes` directly.
- `@Published var calibrationOffsetDBA: Double` — SPL calibration (default 100,
  persisted as `sherlockeq.calibrationOffsetDBA`). Setting it also records the
  volume anchor (`sherlockeq.calibrationAnchorVolumeDB` / `…AnchorDeviceUID`).
- `let systemVolume: SystemVolumeController` — always-on system-output-volume
  tracker (volume dB, mute, device UID) feeding the volume-aware calibration.
- `@Published private(set) var volumeDeltaDB: Double` +
  `var effectiveCalibrationOffsetDBA: Double` — live volume shift and the
  offset the analyzers/dose/meters actually consume (base + delta). See
  `volume-aware-dose.md`.
- `func activeProfile(in store: ProfileStore) -> HearingProfile?`
- `func adoptDefaultProfileIfNeeded(from store: ProfileStore)`
- `func connect(profileStore: ProfileStore)` — subscribes to profile changes and
  pushes them into the engine

---

### 7.4 Data Models

```swift
struct HearingProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var symbol: String                              // SF Symbol
    var linkedDeviceUID: String?
    var leftEar: EarProfile
    var rightEar: EarProfile
    var leftNotch: TinnitusNotch
    var rightNotch: TinnitusNotch
    var separateNotch: Bool
    var globalTrimDB: Double                        // -12…+12
    var balance: Double                             // -1…+1
    var autoEQCurveURL: URL?                        // legacy decode-only
    var autoEQName: String?
    var autoEQBands: [EQBand]?
    var autoEQPreampDB: Double?
    var safeListeningCeilingDB: Double              // default 85
    var compensationFactor: Double                  // 0.25…1.0
    var separateChannels: Bool
    var eqMode: EQMode                              // .simple / .speech / .advanced / .expert
    var isBuiltIn: Bool                             // factory preset marker (editable, not locked)
    var presetDescription: String?                 // factory-preset card copy
    var presetTags: [String]                       // factory-preset best-use tags
    var createdAt: Date
    var modifiedAt: Date
}

struct EarProfile: Codable, Hashable {
    var thresholds: [AudiogramPoint]
    var bands: [EQBand]
}

struct AudiogramPoint: Codable, Hashable {
    var frequencyHz: Int                            // 250, 500, 1000, 2000, 3000, 4000, 6000, 8000
    var thresholddBHL: Double
}

struct EQBand: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var frequencyHz: Double
    var gaindB: Double
    var bandwidth: Double                           // Q for parametric/notch; octaves for shelves
    var filterType: EQFilterType                    // parametric, lowShelf, highShelf, notch, bandPass, lowPass, highPass
    var enabled: Bool
}

struct TinnitusNotch: Codable, Hashable {
    var enabled: Bool
    var frequencyHz: Double                         // typically 1000…16000
    var depthdB: Double                             // negative, typically -3…-15
    var qWidth: NotchWidth                          // .narrow (Q 8) / .medium (Q 4) / .wide (Q 2)
}

enum EQMode: String, Codable, CaseIterable { case simple, speech, advanced, expert }
```

`HearingProfile` carries a custom `init(from decoder:)` so older JSON (pre-balance,
pre-isBuiltIn, single shared `notch`) still loads with safe defaults; encoding
stays synthesized.

---

### 7.5 Safe Listening Calculation

NIOSH equal-energy (3 dB exchange rate). From `SafeListeningTracker`:

```swift
static func permissibleDuration(at dBA: Double) -> TimeInterval {
    nioshReferenceDuration / pow(2.0, (dBA - nioshReferenceLevelDBA) / nioshExchangeRateDB)
}

// Per-sample accumulation (~10 Hz, self-times on wall clock):
let perm = Self.permissibleDuration(at: clampedDBA)
if perm.isFinite, perm > 0 {
    sessionDose = min(1.0, sessionDose + chunk / perm)   // 1.0 = 100% of daily limit
}
```

Level estimate: RMS of post-EQ FFT spectrum, A-weighted per-bin via standard
A-weighting coefficients. The dBA the user sees is dBFS +
`effectiveCalibrationOffsetDBA` — the user's calibration shifted by the live
system-volume delta since calibration time (`CalibrationVolumeAnchor.deltaDB`,
0 when tracking can't apply; −120 while muted). See §5.4 and
`volume-aware-dose.md`.
"Remaining minutes" derives from a 60s power-domain rolling average (NIOSH math is
logarithmic, so arithmetic averaging of dBA would be wrong by ~3 dB per 6 dB of
peak-to-mean).

---

## 8. UI Structure

### 8.1 Menu Bar

- Implemented as SwiftUI `MenuBarExtra` with `.menuBarExtraStyle(.window)`.
- Icon: `MenuBarIcon` (renders `waveform.and.magnifyingglass` and tints amber/red
  for dose warnings via `safeListening.sessionDose`).
- Click: opens the popover.

A full AppKit main menu (`NSApp.mainMenu`) is installed by `AppDelegate`:
- **App menu** — About, Check for Updates… (Sparkle), Hide / Hide Others / Show All,
  Quit.
- **File menu** — Close Window (⌘W).
- **Edit menu** — Undo (⌘Z), Redo (⌘⇧Z), Cut/Copy/Paste/Select All. Dispatch via
  responder chain to the window's `UndoManager` (returned by
  `windowWillReturnUndoManager`).
- **Audio menu** — Toggle Reference Mode (⌘B).
- **Window menu** — Minimize, Zoom, SherlockEQ (⌘0 to show main window).

The menu is reinstalled on `applicationDidBecomeActive` because SwiftUI overrides
`NSApp.mainMenu` on scene activation.

---

### 8.2 Main Popover (380pt wide)

The 5-second surface. Dismisses on click-outside. No charts or canvases.

```
┌──────────────────────────────────────────┐
│  ≋ SherlockEQ      [device label]   [↗]  │  ← arrow opens main window
├──────────────────────────────────────────┤
│  [ NoticeBanner (when active) ]          │
├──────────────────────────────────────────┤
│  Session  ████████░░░░  67%  ~1h 20m     │  ← dose bar
│  Level   L ▓▓▓▓▓░░░░░  R ▓▓▓▓░░░░░       │  ← stereo level strip
│  Gain    ─────●─────── −2.3 dB    ↺      │  ← master gain
│  Balance ──────●────── Center     ↺      │  ← balance (active profile)
├──────────────────────────────────────────┤
│  Profile  [ Afternoon – AirPods    ▾ ]   │
│  Compensation  ○────────●────────○       │  ← one slider that matters most
│  Tinnitus Notch  ●—— ON   4,200 Hz       │
│  [        🔴 Reference Mode         ]    │  ← prominent
└──────────────────────────────────────────┘
```

On first appearance the popover calls `audioState.startAll()` so users don't have
to dig into Debug to bring the tap up.

The arrow button hands off to `AppDelegate.showMainWindow`, which owns the NSWindow
and sequences the `.accessory → .regular` policy flip + activation deterministically.

---

### 8.3 Main Window (default 1480 × 880pt, minimum 1400 × 740pt, resizable)

`NavigationSplitView` with a left sidebar (min 220 / ideal 240 / max 300pt), detail
content in the middle (min 760 / ideal 820pt), and a persistent right monitor
sidebar (220pt) toggleable from the toolbar.

**Sidebar groups** (`SidebarView`):

- **Audio Processor** — Audiogram, Equalizer, Tinnitus Notch, Listening Comfort, Safe Listening
- **App** — Settings, Debug
- Bottom safe-area inset: active profile name (read-only label) + "Manage
  Profiles" button (selects the Profiles section). Profiles is reachable via this
  shortcut, not from the section list, to avoid a duplicated top+bottom entry.

**Profiles** — list of profiles with create / duplicate / delete / import / export /
restore-factory in the toolbar; rows show name, factory star badge, description, and
tag chips. Detail panel shows name, symbol, linked device UID, EQ mode picker,
balance, global trim, safe-listening ceiling, AutoEQ correction (file picker plus
the library-folder menu plus the AutoEQ remote search view). The four factory presets
(§5.8) are fully editable; they show a banner with "Reset to Factory Default" (enabled
once edited) and Duplicate. "Restore Factory Presets" in the toolbar rebuilds all four.

**Audiogram** — interactive audiogram chart for the active profile (Left ear / Right
ear tabs). Draggable threshold points at standard frequencies plus numeric entry
alongside. EQ preview rendered below.

**Equalizer** — shows the single EQ surface that matches the active profile's
`eqMode`. The four modes:
- *Simple* — three slots (250 Hz low-shelf, 1 kHz parametric, 5 kHz high-shelf)
- *Speech* — six slots (60 Hz low-shelf, 200 / 800 / 2500 / 6000 Hz parametric,
  12 kHz high-shelf) tuned for voice intelligibility
- *Advanced* — 12-band graphic EQ on the audiometric grid (31.5, 63, 125, 250,
  500, 1k, 2k, 3k, 4k, 6k, 8k, 16k Hz — the octave series plus the 3 & 6 kHz
  audiogram frequencies; canonical list: `EQMode.graphicCenters`)
- *Expert* — full parametric canvas (draggable nodes, biquad curve, spectrum
  underlay, layer chip strip, AutoEQ + audiogram + safety overlays, L/R link)

Switching modes is non-destructive: bands the other modes wrote stay in storage and
just hide. A "hidden bands" hint chip surfaces them when relevant.

**Tinnitus Notch** — Tone Finder + notch controls on one screen. Frequency sweep
(1 kHz – 16 kHz), fine-tune stepper, volume row, "Set as notch frequency". Notch
controls: frequency / depth / width per ear (Linked or Separate, via the
`separateNotch` toggle).

**Safe Listening**
- Current level estimate (dBA)
- Session dose bar (large, detailed) with green/amber/red severity
- Configurable personal ceiling, notification preferences, dose reset behavior
- Calibration workflow (plays a 1 kHz / −12 dBFS tone so the user can match SPL
  with an external meter and set `calibrationOffsetDBA`)
- Explanatory section: what the dose estimate is and isn't; link to NIOSH REL

**Settings** (`SettingsView`)
- Startup — Launch at login; Hide from Dock when window is closed
- Output — Master gain
- Limiter — AUPeakLimiter attack / decay / pre-gain
- Appearance — Per-ear colors (left / right)
- Shortcuts — Global Reference Mode shortcut on/off (⌘⇧B when on)
- AutoEQ library folder — pick a folder of `.txt` corrections; appears in the
  Profile-Detail headphone picker menu
- Profile backup location — show / change the on-disk profiles directory (with
  "Move existing" vs "Switch only" prompt)
- About — Acknowledgments (AutoEQ, NIOSH, Sparkle, open-source credits)

**Debug** — diagnostics view (tap state, engine state, sample-rate, frame counters,
permission status, raw FFT bin readout, manual graph rebuild button). Sidebar entry
intentionally exposed for self-support and bug reports.

---

### 8.4 Onboarding

Implemented as a **lean three-step first-launch wizard** (`UI/Onboarding/OnboardingView.swift`),
shown once and gated by `AppPreferences.hasCompletedOnboarding`
(UserDefaults `sherlockeq.hasCompletedOnboarding`). `AppDelegate` owns the
hosting window (`showOnboardingWindow()`, same `.accessory → .regular`
activation dance as the Help / Analog windows) and branches `bootstrap()`:
returning launches keep the prior behavior, while a fresh install **defers the
notification + system-audio permission prompts** and shows the wizard instead,
so those prompts arrive *after* an explanation rather than cold. The three steps:

1. **Welcome** — what SherlockEQ does, plus the mandatory upstream-EQ note (below).
2. **Permissions** — primes the non-obvious **System Audio Recording** TCC grant
   (`kTCCServiceAudioCapture`) with plain language before macOS asks, then a
   "Grant access" button that calls `AudioCapturePermission.request()`. Because
   `preflight()` can't distinguish "never asked" from "denied", the UI always
   offers Grant access first and only falls back to an "Open System Settings"
   deep link *after* a failed request. Notifications are offered as an optional,
   skippable grant. Denials route through `NoticeCenter`.
3. **Profile** — pick one of the four factory listening presets (§5.8), shown as
   cards with description + tag chips in canonical order, default **Music Balanced**,
   plus a "listening-comfort presets, not medical hearing correction" line. Optional
   "Where to next?" rows deep-link to the Audiogram / Tinnitus Notch / Safe Listening
   screens via `AudioState.pendingMainSection` (observed by `MainWindowView`).

On finish or skip, `AppDelegate.finishOnboarding` sets the gate flag, runs the
deferred permission/start work, and optionally opens the main window on the
chosen section. Re-runnable any time from **Settings → About → "Replay intro"**.

Deliberately **not** a deep guided audiogram / tinnitus / calibration wizard:
those are first-class screens now, so onboarding points at them rather than
duplicating them inline.

The wizard includes a brief upstream-EQ note: equalizers
inside other apps (e.g. Music's EQ, Sound Check) are applied within those apps
before SherlockEQ's tap captures the mix, so they stack underneath the hearing
correction and cannot be detected or compensated from the tap side. Recommend
setting other apps' equalizers flat. (A matching footnote also ships on the
Equalizer screen; the wizard reuses the wording.) Optional future enhancement:
Music's EQ state is queryable via Apple Events (`EQ enabled` / `current EQ
preset` in Music's scripting dictionary) — requires an
`NSAppleEventsUsageDescription` string, a TCC Automation prompt, and a
running-Music guard (querying a non-running app launches it); covers Music only,
so it would supplement the note rather than replace it. Not built.

---

## 9. Project File Structure

```
SherlockEQ/
├── SherlockEQApp.swift                     ← @main, MenuBarExtra scene
├── AppDelegate.swift                       ← NSWindow ownership, activation policy,
│                                             AppKit main menu, multi-instance guard,
│                                             global hotkey, NotificationManager bootstrap
│
├── Audio/
│   ├── CATapEngine.swift                   ← CATap + per-ear source nodes + cascades
│   ├── SherlockEQAudioEngine.swift         ← AVAudioEngine graph, balance, limiter, gain
│   ├── BiquadCoefficients.swift            ← Audio EQ Cookbook coefficient math
│   ├── BiquadCascade.swift                 ← Per-ear render-block cascade
│   ├── BiquadResponse.swift                ← Magnitude response for curve drawing
│   ├── SpectrumAnalyzer.swift              ← vDSP DFT, A-weighting, dBA conversion
│   ├── StereoMonitor.swift                 ← L/R peak metering for the monitor surfaces
│   ├── VUMeter.swift                       ← Analog VU ballistics
│   ├── AudiogramConversion.swift           ← dB HL → EQBand
│   ├── EQBandLookup.swift                  ← Mode → slot mapping for hidden-band hints
│   ├── SineToneGenerator.swift             ← Tone Finder + diagnostic test tones
│   ├── AutoEQParser.swift                  ← Parse AutoEQ .txt → preamp + [EQBand]
│   ├── AutoEQLibrary.swift                 ← Local library folder enumeration
│   ├── AutoEQRemote.swift                  ← Phase-1 fetcher (online/offline/ratelimit)
│   ├── AutoEQRemoteService.swift           ← Catalog + profile fetch, cache, errors
│   ├── AutoEQConflictDetector.swift        ← Warn on AutoEQ-vs-manual conflicts
│   ├── AudioCapturePermission.swift        ← kTCCServiceAudioCapture wrapping
│   ├── TapRingBuffer.swift                 ← Lock-free ring between tap IOProc and source
│   ├── AudioCounter.swift                  ← Lock-protected diagnostic counters
│   ├── SystemVolumeController.swift        ← macOS output volume read/write + dB/mute/UID
│   ├── VolumeAnchoredCalibration.swift     ← Calibration volume anchor + delta math
│   └── GlobalHotKey.swift                  ← Carbon RegisterEventHotKey wrapper (⌘⇧B)
│
├── State/
│   ├── AudioState.swift                    ← Top-level ObservableObject composing all sub-state
│   ├── EQChainState.swift                  ← referenceMode + per-stage bypass toggles
│   ├── EngineParameters.swift              ← masterGain + limiter knobs
│   ├── AppPreferences.swift                ← Per-ear colors, dock, launch-at-login, hotkey
│   ├── AutoEQPreferences.swift             ← AutoEQ library folder
│   ├── NoticeCenter.swift                  ← Shared notice banner state
│   ├── NotificationManager.swift           ← UNUserNotificationCenter wrapper
│   └── SafeListeningTracker.swift          ← NIOSH dose accumulator
│
├── Models/
│   ├── HearingProfile.swift                ← incl. EQMode enum
│   ├── EarProfile.swift
│   ├── AudiogramPoint.swift
│   ├── EQBand.swift                        ← incl. EQFilterType enum
│   └── TinnitusNotch.swift                 ← incl. NotchWidth enum
│
├── Persistence/
│   ├── ProfileStore.swift                  ← <UUID>.json files, undo coalescing, relocation
│   └── AutoEQSavedProfilesStore.swift      ← Persisted AutoEQ corrections
│
├── Updates/
│   └── UpdaterController.swift             ← Sparkle (SUUpdater) wrapper
│
├── UI/
│   ├── Popover/
│   │   ├── MainPopoverView.swift
│   │   ├── MenuBarIcon.swift               ← Menu-bar label icon w/ dose tinting
│   │   ├── DoseBarView.swift
│   │   ├── PopoverLevelStrip.swift         ← Stereo L/R peak meter strip
│   │   ├── ProfilePickerRow.swift
│   │   ├── CompensationSliderView.swift
│   │   ├── TinnitusNotchRow.swift
│   │   └── ReferenceButton.swift
│   │
│   ├── Window/
│   │   ├── MainWindowView.swift            ← NavigationSplitView + right monitor sidebar
│   │   ├── Sidebar/
│   │   │   ├── SidebarView.swift
│   │   │   └── SidebarSection.swift        ← profiles, audiogram, equalizer, toneFinder, safeListening, settings, debug
│   │   ├── Profiles/
│   │   │   ├── ProfilesView.swift
│   │   │   ├── ProfileListItem.swift
│   │   │   ├── ProfileDetailView.swift
│   │   │   └── AutoEQSearchView.swift      ← Remote catalog search + import
│   │   ├── Audiogram/
│   │   │   ├── AudiogramView.swift
│   │   │   ├── AudiogramChartView.swift
│   │   │   ├── ThresholdEditor.swift
│   │   │   └── EQPreviewView.swift
│   │   ├── Equalizer/
│   │   │   ├── EqualizerView.swift         ← Switches on profile.eqMode
│   │   │   ├── SimpleEQView.swift
│   │   │   ├── SpeechEQView.swift
│   │   │   ├── AdvancedEQView.swift
│   │   │   └── ExpertEQView.swift
│   │   ├── ToneFinder/
│   │   │   └── ToneFinderView.swift        ← Sidebar title: "Tinnitus Notch"; bundles Tone Finder + notch controls
│   │   ├── SafeListening/
│   │   │   ├── SafeListeningView.swift
│   │   │   └── LevelMeterView.swift
│   │   ├── Monitor/
│   │   │   └── MonitorSidebar.swift        ← Right-hand panel: VU, gain, balance, dose
│   │   ├── Meters/
│   │   │   └── AnalogVUMeter.swift         ← Analog VU dial (MonitorSidebar + Analog Control Unit + popover easter egg)
│   │   ├── Settings/
│   │   │   ├── SettingsView.swift
│   │   │   └── AcknowledgmentsView.swift
│   │   └── Debug/
│   │       └── DebugView.swift
│   │
│   └── Components/
│       ├── ParametricCanvasView.swift      ← Expert canvas (spectrum underlay + curves)
│       ├── NotchControlView.swift
│       ├── NoticeBannerView.swift
│       ├── BuiltInProfileBanner.swift
│       ├── EQBypassButton.swift
│       ├── EQGainChip.swift
│       ├── HiddenBandsHintChip.swift
│       ├── CanvasLayerChipStrip.swift
│       ├── LogFreqAxis.swift
│       ├── PlaceholderView.swift
│       ├── ColorHex.swift
│       └── UndoManagerLink.swift           ← Pipes SwiftUI undoManager into ProfileStore
│
└── Resources/
    ├── Assets.xcassets                     ← AppIcon (accent left to system default)
    ├── Info.plist
    └── SherlockEQ.entitlements
```

`UI/Onboarding/OnboardingView.swift` — the lean three-step first-launch wizard
(welcome + upstream-EQ note → permission priming → starter-profile pick). See §8.4.

---

## 10. Entitlements & Info.plist

`SherlockEQ.entitlements`:
```xml
<key>com.apple.security.device.audio-input</key>
<true/>
```

`Info.plist` (selected keys):
```xml
<key>LSUIElement</key><true/>                              <!-- start as menu-bar agent -->
<key>LSApplicationCategoryType</key><string>public.app-category.music</string>

<!-- NOTE (updated after this spec): the app ships ONLY NSAudioCaptureUsageDescription.
     NSMicrophoneUsageDescription was removed — CATap reads other processes' audio via
     the process-tap API, not an input device, so the app never requests microphone TCC
     and no "Microphone" prompt appears. The entitlements file is empty (no audio-input). -->
<key>NSAudioCaptureUsageDescription</key>
<string>SherlockEQ uses this permission to capture system audio through Apple's Core Audio Tap API. It does not record audio to disk.</string>

<!-- Sparkle auto-update -->
<key>SUFeedURL</key>      <string>https://snxt.ai/appcast.xml</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUPublicEDKey</key>  <string>wltqWmlE8DlhQFGVxSRGLO06xjRrYO3jDIu8h3SYx58=</string>
```

A single privacy string is used — `NSAudioCaptureUsageDescription`, the
"System Audio Recording" bucket (user-visible name on macOS 15+; on 14.x the
`kTCCServiceAudioCapture` service is grouped under Screen Recording in the
Settings UI). The app deliberately does NOT use `NSScreenCaptureUsageDescription`
or the CGRequest screen-capture APIs — CATap belongs in System Audio Recording
only. It also does NOT request microphone TCC (no `NSMicrophoneUsageDescription`,
no `audio-input` entitlement): the process-tap API reads other apps' audio
without an input device, so a "Microphone" prompt would be misleading.

App is NOT sandboxed (`ENABLE_APP_SANDBOX = NO`); hardened runtime is on
(`ENABLE_HARDENED_RUNTIME = YES`). No privileged helper, no driver installation,
no password prompt.

Distribution: notarized DMG with Sparkle-signed appcast (EdDSA). Not App-Store
distributed (Core Audio Taps requires `audio-input` outside the sandbox).

---

## 11. Open Questions

| Item | Notes |
|------|-------|
| App Store distribution | Core Audio Taps requires `com.apple.security.device.audio-input` outside the App Store sandbox. Current plan: notarized DMG distribution (same model as eqMac). |
| dBHL → EQ accuracy | **Resolved.** Shipped as the **NAL-R** prescription (Byrne & Dillon 1986), replacing the linear 0.5× half-gain heuristic. The ISO 226 dBSPL-conversion approach was evaluated and **rejected** — dB HL is already per-frequency normalised, so gaining from SPL would over-boost lows even for normal hearing. See `AudiogramConversion.swift`. |
| Cubic-spline interpolation | Spec §5.2 originally called for cubic-spline-derived intermediate bands. Not implemented — `AudiogramConversion.bands(for:compensationFactor:)` emits one band per audiogram point. Adding interpolation later would not change the function signature. |
| Spectrogram visualisation | **Removed** (2026-07 scope-reduction pass) along with the 1/3-octave bars mode, peak callouts, lens presets, vectorscope, and waveform scope. These were mixing-engineer instruments serving no hearing-accommodation purpose; the code was deleted rather than left dormant. The Analog Control Unit and analog VU dial were deliberately kept (nostalgia is their purpose). Git history has the deleted implementations if ever needed. |
| Onboarding wizard | Implemented as a lean three-step first-launch wizard (§8.4): welcome + upstream-EQ note → permission priming (defers the system-audio + notification prompts so they arrive with context) → starter-profile pick with optional deep-links. Replayable from Settings → About. The deeper guided audiogram / tinnitus / calibration steps the original spec imagined were deliberately left as deep-link pointers to the now-first-class screens. |
| AutoEQ license | AutoEQ data is MIT licensed. Credit lives in Settings → About → Acknowledgments with a link to the upstream repo. |
| Window sizing | Current minimum 1400 × 740pt is set so the Expert layer-chip strip and the dual sidebars fit on one row without compression. Lowering the floor would require collapsing the right monitor sidebar by default. |
