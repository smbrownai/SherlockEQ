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
main window for configuration — plus an on-demand right-hand monitor panel inside the
main window (collapsed by default, opened from a compact toolbar status).

### Menu Bar Popover (380pt wide)
The popover is for **operating** SherlockEQ, not configuring it. It dismisses when you
click away. Implemented as a SwiftUI `MenuBarExtra` with `.menuBarExtraStyle(.window)`.

What belongs here (top → bottom):
- Header: app name + read-only current output device label, with a one-line
  processing status underneath ("Processing <profile>" / "Reference Mode —
  processing bypassed" / "No active profile — audio passing through")
- Notice banner (shared `NoticeCenter` — also rendered in the main window)
- Output level strip (live L/R meters; shows a waiting state while no audio
  is playing)
- Session dose bar (percent + remaining minutes) with an honest exposure
  status — tracked / approximate / unknown via `ExposureStatus.resolve`
- Master gain slider (`-60…+12 dB`) with recenter button
- Balance slider (`-1…+1`, per active profile) with recenter button
- Profile picker row
- Reference Mode button (prominent)
- Headphone-correction device-mismatch warning row (only when mismatched)
- "Processing details" disclosure (collapsed by default; expansion persists
  via `@AppStorage`): read-only Hearing adjustment / Listening comfort /
  Tinnitus notch status rows
- Footer rows: Open Main Window · Health & Safety · Quit SherlockEQ

What does **not** belong here:
- Audiogram entry
- Parametric EQ canvas
- Spectrum analyzer
- Profile creation or editing
- Settings
- Output device picker (the popover shows the current device as a read-only label;
  device routing follows the macOS default output. Profile→device auto-switching is
  configured per profile in Profile Detail.)

### Main Window (default 1480 × 880pt, minimum 1126 × 716pt; minimum width 1387pt while the monitor panel is open)
Opened deliberately from the popover. Appears in the Dock and CMD+Tab while open.
Uses `NavigationSplitView` with a left sidebar and an on-demand right monitor
**panel** (opened from the toolbar's compact status glance — see below).

What belongs here:
- All profile management (create, duplicate, delete, reorder, import, export)
- Audiogram entry (interactive chart + numeric fields)
- Equalizer (Graphic / Parametric — the active profile commits to one
  surface; picker lives on Profile Detail)
- Tinnitus Notch (Tone Finder + notch controls, consolidated)
- Safe Listening detail and history
- All Settings
- Debug diagnostics

### Monitor Panel (collapsed by default)
Opened from the toolbar's **compact status glance** — a `MonitorStatusButton`
reading `Output: <app master gain>  •  Dose: <today's exposure>  •  <active-
profile balance>` (dose tinted by severity). The glance reads only slow state,
so the 60 Hz VU loop stays idle until the panel is open. Clicking it toggles
the panel as an in-layout trailing column that slides in within the detail
area (chosen over SwiftUI's native `.inspector`, which resized/shifted the
whole window and animated jerkily — the in-layout slide keeps both gutters
aligned and moves nothing outside the detail). Contents, each with an **explicit scope
label** (so it's never ambiguous whether a value is app-wide or per-profile —
the sliders also appear on the popover / Settings / Profile Detail):
1. Output level VU — vertical L/R peak meter. Triple-tap the header to swap
   between the Digital and Analog VU displays (the analog dial is the
   nostalgic easter egg shared with the Analog Control Unit).
2. **App master gain** slider (`-60…+12 dB`) — app-wide, same value as the
   popover and Settings.
3. **Active profile balance** slider (`-1…+1`) with recenter button — saved
   with the active profile (same as Profile Detail's balance row).
4. **Today's exposure** mini-bar — today's NIOSH dose as a thin
   green/amber/red capsule (resets at local midnight).

Visibility persisted via `@AppStorage("sherlockeq.monitorSidebarVisible")`.

### Health & Safety disclosure (three-tier model)

Health/safety disclosure follows one architecture with a single source of
truth (`HealthSafetyDisclosure`) so wording can't drift into slightly
different per-view copies:

1. **Persistent access** — a **Health & Safety Info** row in the sidebar's
   App group, above Settings (the bottom safe-area footer holds only the
   active-profile control). Reachable from every main screen,
   keyboard-operable, VoiceOver-labeled, understandable from its text alone
   (icon decorative). Opens the consolidated **`HealthSafetySheet`** (native
   `.sheet`, presented at the window level via `AudioState.showHealthSafety`).
   The sheet is calm and scannable: intro summary + the sections About /
   Not a medical device or hearing aid / Audiograms & hearing adjustments /
   Tinnitus tools & test tones / Listening-level estimates & calibration /
   Safe use & when to stop / When to consult a professional / Privacy & local
   processing / Learn more, each linking to the relevant Help article. Done
   button; full keyboard + VoiceOver; Dynamic-Type friendly; no color-only
   meaning.
2. **Contextual just-in-time notices** — one-or-two-sentence `SafetyNote`s (or
   inline copy) kept where timing matters, each with a "Learn more" link:
   start-quiet/stop-if-uncomfortable at the tone transport (the tinnitus
   red-flag symptom list lives only in the Health & Safety sheet's "What
   SherlockEQ can't assess" section), large-boost warning past +9 dB
   (Graphic EQ), audiogram "starting point, not a clinical fitting"
   (Audiogram), the calibration-confidence badge + "Waiting for audio"
   (Safe Listening), and the Listening Check's estimate framing. These never
   repeat the full general disclosure.
3. **Detailed background → Help** — the deep-dive (NIOSH exchange rate,
   NAL-R rationale, notched-sound evidence, privacy specifics) lives in the
   Help articles; the sheet and notices summarize and link.

Repeated general-purpose "not a medical device" cards (Clarity, Safe Listening)
are replaced by the compact **`HealthSafetyChip`** ("Consumer audio tools —
not medical care. Health & Safety…"), which opens the same sheet. This changes
none of the app's medical-device status, intended purpose, audio behavior, or
safety policies — only how the disclosure is organized and surfaced.

**Testing.** `HealthSafetyDisclosureTests` (unit) pins the content — all
sections present, every required plain-language statement present, all Help
links resolve. A dedicated **`SherlockEQUITests`** XCUITest bundle (in the
shared `SherlockEQ` scheme's test action alongside `SherlockEQTests`) covers
the interaction: opening/dismissing the sheet (footer button, Done, Escape),
reachability from every main destination, the required section headings, and
Help-link navigation. UI tests launch the app with the **`-uitest`** argument
(`AppDelegate.isUITesting`), which opens the main window and skips the audio
pipeline, CLI, notifications, and onboarding for a deterministic run.
Defaults to **closed**: the panel's usual state was an idle low-information
repeat, and the live glance now lives in the toolbar status.

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
- `separateChannels: Bool` — toggles per-ear UI for both EQ
  surfaces (default false: single-column UI; symmetric-hearing users keep it off)
- `eqMode: EQMode` — `.advanced` (display name **Graphic**) or `.expert`
  (display name **Parametric**). Two surfaces onto the same band array; persisted
  raw values are frozen for JSON compatibility, and the retired v1 modes
  ("simple", "speech") decode onto Graphic. Switching is non-destructive — the
  Graphic surface exposes any band it can't edit via its "Other filters" row
  (convert-to-sliders fit, or the Parametric escape hatch). New profiles default
  to `.advanced`; a profile JSON with no eqMode at all decodes `.expert`.
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

**Entry methods:**
1. Interactive chart with draggable threshold points per ear, plus numeric
   fields alongside. Values entered in **dB HL** (hearing level, as reported
   on audiograms). Left/right tab on the same screen.
2. Audiogram interchange import (JSON), via the Manage Audiogram menu.
3. **The Listening Check** (phase-3 §4, `ListeningCheckSession` +
   `ListeningCheckView`): a guided in-app estimate using the modified
   Hughson–Westlake staircase (descend 10 / ascend 5; threshold = lowest
   level with 2 ascending responses) at the 8 audiogram frequencies per ear —
   1k → 2k → 3k → 4k → 6k → 8k → 500 → 250 → 1 kHz retest (validity probe,
   never averaged; > 10 dB divergence flags low reliability). Pulsed tones
   (3 × 200 ms, 5 ms raised-cosine edges) through the Tone Finder generator
   (bypasses EQ; per-ear channel mask), ~15 % silent catch trials (> 2 false
   alarms flag reliability), **hard safety ceiling**
   `min(−25 dBFS, 80 dBA − effectiveCalibrationOffsetDBA)` — no response at
   the ceiling records *unmeasurable* (excluded from NAL-R) rather than ever
   presenting louder. dBFS → dB HL via the volume-anchored calibration plus a
   generic supra-aural RETSPL table; the ±5–10 dB anchor uncertainty is
   disclosed (shape survives; NAL-R is shape-dominated). Volume changes
   mid-run pause the check; a device change invalidates and restarts it;
   built-in speakers are blocked outright. Apply feeds the exact manual-entry
   path (full-strength derivation + acclimatization ramp) and stamps
   provenance: `audiogramSource` (.manual / .listeningCheck / .imported) +
   `audiogramDate`, shown on the Audiogram screen. Framed everywhere as a
   "listening check" / estimate — never a hearing test, never diagnostic.

**Conversion to EQ** (`AudiogramConversion.bands(for:compensationFactor:)`):
- > **Implemented (updated after this spec):** the linear half-gain formula below
  > was the original design. Shipping code uses the **NAL-R** prescription
  > (Byrne & Dillon 1986): `REIG(f) = X + 0.31·HTL(f) + k(f)`, with
  > `X = 0.05·(HTL₅₀₀ + HTL₁₀₀₀ + HTL₂₀₀₀)`. `compensationFactor` is now an overall
  > strength multiplier on the whole prescription (not the gain fraction). The
  > ceiling, disable-threshold, band count, and slider below still hold.
- `gain_at_freq = threshold_dBHL × compensation_factor` *(original design; superseded by NAL-R)*
- `compensationFactor` range `0.25…1.0` is the user's TARGET strength,
  applied at **consumption time** (phase-3 §5): stored `correctionBands`
  carry the full NAL-R prescription, and every consumer — engine, previews,
  canvases, conflict check — reads `effectiveCorrectionBands(now:)` =
  stored × (target × acclimatization ramp). (Previously the factor was
  baked in at derivation, which left the strength sliders writing a value
  nothing re-derived from — an inaudible no-op. Legacy stored corrections
  re-derive to full strength on decode; net audio unchanged.)
- **Acclimatization ramp** (`AcclimatizationRamp`): the FIRST audiogram
  applied to a profile sets the target to 1.0 (full prescription) and stamps
  `acclimatizationStartDate`; effective strength rises 60 % → 100 % linearly
  over 21 days (re-applied on `NSCalendarDayChanged`; ≤ ~0.7 dB per day —
  inaudible as a transition). Ongoing audiogram edits never restamp. A
  labeled chip (Audiogram screen + Profile Detail) shows "Gradual adjustment:
  day N of 21 — X % strength." with "Skip to full strength" (clears the
  stamp).
  Legacy profiles (no stamp) ramp at 1.0 — nothing changes until their next
  first-application.
- Hard ceiling: no single band boosted more than **+20 dB** regardless of loss
  (`AudiogramConversion.perBandCeilingDB`)
- Bands disabled when pre-compensation loss is < 5 dB HL (no audible boost needed)
- One band emitted per audiogram point (8 bands per ear). Cubic-spline-derived
  intermediate bands are not implemented — the algorithm signature can absorb that
  later without API churn.
- User adjusts `compensationFactor` via the **Adjustment strength** slider
  (Profile Detail → Advanced tuning). The popover's copy of the slider was
  removed in the status-rows overhaul — it shows a read-only Hearing
  adjustment row instead. Previews caption the value with
  `AdjustmentStrengthLabel` ("Adjustment strength N% · currently M%" while
  the acclimatization ramp makes the two differ).

**Adjustment style — Steady vs Adaptive (phase 4):** a segmented selector on
the Audiogram screen (below the chart, shown only when correction exists)
writes `profile.correctionMode` (`.steady` default / `.adaptive`, tolerant
decode). **Terminology:** user-facing copy calls the audiogram-derived
processing a **"hearing adjustment"** (not "correction") — "correction" implies
a verified clinical fitting this deliberately isn't. Code identifiers keep the
`correction*` names (`correctionMode`, `correctionBands`, …); "headphone
correction" (AutoEQ) is a separate, unchanged term. Steady applies the stored correction as fixed EQ in the static
cascade; Adaptive routes it through the `AdaptiveCorrectionProcessor`
(6-band level-following gains anchored to the NAL-R curve at 65 dB SPL —
see phase4-adaptive-correction.md). Supporting UI:
- **Level-aware preview** (`AdaptivePreviewView`): in Adaptive mode the
  Audiogram preview card draws the correction *family* for the displayed
  ear — three curves at 50/65/85 dB SPL input (quiet/moderate/loud), the
  65 dB anchor emphasized (it equals the Steady curve). Pure math: the §1
  prescription's gains through `AdaptiveFilterbank.compositeMagnitudeDB`
  (the drawing-side twin of `process`, test-pinned to the time-domain
  response) plus the user-EQ biquad composite.
- **Live overlay** (`AdaptiveActivityMonitor` → both EQ canvases): the
  stage's current per-band gains, polled at 15 Hz from the processor's
  `AudioCounter`s (the DynamicActivityMonitor pattern — refcounted,
  screen-sleep-paused, never rebroadcast through AudioState) and drawn as
  a dashed ear-tinted stroke; hidden while all gains are within 0.1 dB of
  unity.
- **Reduced-depth honesty line**: when Adaptive is selected without a user
  playback calibration, a warning under the selector says it is running in
  reduced-depth mode (§7.3 of the phase-4 spec).

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

**Conflict detection** (phase-3 §6, `CorrectionConflict`): presbycusic tinnitus
typically sits in the region of maximum loss, so the notch often lands exactly
where NAL-R prescribes its largest boost — one filter bank arguing with itself.
When the correction boosts ≥ +4 dB at an enabled notch's center and the notch
cuts ≤ −6 dB, a persistent chip appears on both the Tinnitus Notch and
Audiogram screens (per-ear; collapsed to one line when both ears match)
explaining the tradeoff — narrower notch keeps more correction, shallower
notch keeps more relief — with a deep-link to the other surface. Detection
only; no auto-fix.

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

**Main window — Safe Listening view:** organised around the two live questions —
**"How loud is it now?"** and **"Today's exposure"** — at the top, each carrying a
calibration-confidence badge so the presented precision never implies more
certainty than exists:
- **Confidence badge** next to the live dBA: **Not calibrated** (no user
  calibration → rough default), **Approximate** (calibrated but volume unreadable
  / different device), or **Calibrated** (calibrated and volume-tracking active),
  derived from `hasUserCalibration` + `volumeTrackingStatus`.
- **Waiting for audio** — when the level reading is below the meter floor the live
  card shows "Waiting for audio" rather than a misleading "Safe" verdict.
- **Remaining safe time** is surfaced as the actionable figure once calibrated
  (dose % otherwise).
- The profile's limit is labelled **"Listening limit"** (was "Ceiling").
- **Calibration** (an SPL-meter setup task, not a daily one) lives in its own
  **sheet** opened from a short "Calibrate for more accurate level estimates" row;
  the tone + meter-reading workflow and the volume-tracking status line moved
  there.
- **Quiet threshold**, the 80/100 % notification toggle, and **Reset today's
  dose** (now confirmation-gated and de-emphasised) sit under an **Advanced**
  disclosure.

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

**Device-mismatch detection** (phase-3 §7, `AutoEQMismatch`): attaching a
correction records the then-current output device
(`autoEQDeviceUID`/`autoEQDeviceName` on the profile). When the active
profile's correction is enabled but the current output's UID differs,
`AudioState.autoEQMismatch` publishes a warning surfaced in the popover
(below the compensation slider) and above the Equalizer — with **Bypass
here** (flips the existing session `autoEQEnabled` stage toggle) and
**Dismiss** (remembered per profile + device pair in UserDefaults; a new
combination warns again). Identity comparison only — no fuzzy model-name
matching; legacy corrections with no recorded UID never warn. Built-in
speakers get categorical copy (a headphone curve there is always wrong).
Never auto-bypasses — no silent audio changes.

---

### 5.8 Factory Listening Presets

Four shipped **listening-comfort presets**, each wrapping one shared
**`PresetCurve`** — the outcome-named curve table (v2, phase-3 §3) that also
powers the Graphic EQ's purpose-preset selector, so the factory cards and the
in-EQ presets can't drift apart. These are tone/comfort presets — **not**
medical hearing correction; copy never implies treating hearing loss,
tinnitus, or any condition. Each has a stable id, `eqMode: .advanced`,
identical L/R bands, the curve's output trim in `globalTrimDB`,
`isBuiltIn: true`, and outcome-language `presetDescription` + `presetTags`.
Canonical UI order: Voice Clarity, Music Balanced, Gentle Listening,
**Reduce Boom** (which replaced the retired Presence Boost — Voice Clarity at
~60 % scale, a redundant slot). The cold default (and onboarding default) is
**Music Balanced**, now voiced to be clearly audible on a Reference-Mode A/B.

The `PresetCurve` table (gains on the 12-band grid 31.5 / 63 / 125 / 250 /
500 / 1k / 2k / 3k / 4k / 6k / 8k / 16k Hz):

| Curve | Factory card | Gains (dB) | Trim |
|---|---|---|---|
| Flat | — | all 0 | 0 |
| Clearer voices | Voice Clarity | −4, −3, −2, −1, 0, +1, +2, +2.5, +3, +2, +1, −1 | −2 |
| Music balance | Music Balanced | +1.5, +2, +1, −0.5, −0.5, 0, +1, +1.5, +1.5, +1, +0.5, 0 | −1 |
| Gentle listening | Gentle Listening | 0, 0, +0.5, +0.5, 0, 0, −0.5, −1, −2, −3, −3.5, −4.5 | 0 |
| Reduce boom | Reduce Boom | −3, −2.5, −2, −1.5, −0.5, 0, +0.5, +0.5, 0, 0, 0, 0 | 0 |
| Reduce harshness | — | 0, 0, 0, 0, 0, −0.5, −1.5, −2.5, −2.5, −1.5, −1, −0.5 | 0 |

The Graphic selector shows these six plus a computed **Custom** state
(whenever sliders + trim diverge from every curve), rendered as a real
bordered **`Preset:` menu button** (not the old borderless capsule, which
read as a link). The genre curves (Warm … Techno, `ToneFlavorPreset`) live
in a **separate sibling `Tone flavors` menu button** labeled *taste presets,
not hearing correction* — previously a nested submenu, which SwiftUI's macOS
`Menu` flashed open then auto-dismissed after ~1 s, making the flavors
unreachable. The former static "Loudness compensation" preset was deleted
outright — a fixed contour impersonating level-dependent equal-loudness is
wrong physics (a correct SPL-keyed version becomes possible with the Phase-1
volume anchoring; future spec).

**Approachability polish (Graphic surface).** The surface is styled as the
app's friendly default rather than a test panel: enlarged frequency and gain
readouts, shortened slider travel with an enlarged response graph, and an
optional **tone guide** — a perceptual caption under each band (Rumble / Bass
/ Warmth / Voice body / Clarity / Sibilance / Air, grouped so adjacent bands
share a word), toggled by `sherlockeq.graphic.toneGuide` (default on). The
reset control reads **Reset to Flat**. When audiogram-derived and/or
headphone (AutoEQ) correction is active, a plain-language **"Additional
correction is active — Audiogram + headphone correction"** note states that a
correction layer runs beneath the graphic bands and is included in the drawn
curve (informational; editing lives on the Audiogram screen / Profile
Detail).

**Factory lifecycle.** `ProfileStore.reconcileFactoryPresets()` (version-gated
on `sherlockeq.factoryPresetsVersion`, now **2**) installs the four on first
launch. On upgrade it never clobbers user work: canonical presets still
matching their **frozen v1 definitions** (`ProfileStore.FrozenFactoryV1`,
full-profile comparison via `profile(_:matchesCanonical:)`) are replaced with
v2; edited ones are left alone. Retired/unknown built-ins (Presence Boost,
ancient random-id legacies) are deleted only when pristine — otherwise
**demoted** to plain user profiles with every edit preserved. A deleted
preset is **not** silently re-added within a version. `restoreFactoryPresets()`
(Profiles toolbar) recreates/resets all four; `resetProfileToFactory(_:)`
reverts one. The limiter stays the existing global setting — no per-profile
limiter state. Transitions remain instant hard-swaps (click-free by the
cascade's state-zeroing + denormal flush); no ramping was added.

The former **Speech EQ mode** was retired in the phase-3 surface consolidation;
its perceptual vocabulary and voice-tuning role fold into the Graphic surface
(labels/help + the upcoming "Clearer voices" purpose preset — see
`phase3-make-correction-land.md` §1/§3).

---

### 5.9 Parametric EQ

The full-control surface. Reached from the **Graphic | Parametric** segmented
control in the Equalizer screen's toolbar (`eqMode = .expert`). Rendered by `ExpertEQView` via
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

**Approachability polish (Parametric surface).**
- **Empty ear:** the empty-state card offers **Add band** (primary,
  `.borderedProminent`, one band at 1 kHz) beside **Create standard 8-band
  EQ** (secondary — the former "Quick start: 8 bands", renamed to say what it
  does). The header's Add band is a real bordered button, not borderless.
- **Selected-band controls** (`controlsBar`) sit immediately below the canvas
  so the select→tune loop stays tight; the keyboard cheat-sheet no longer
  occupies a permanent block below them.
- **Keyboard shortcuts** moved behind a header keyboard-icon button into a
  `.popover` (`shortcutsCard`) — the reference no longer outweighs the
  primary workflow.
- **Bandwidth unit switch** is labeled **Bandwidth** with **Q / Octaves**
  segments (was a bare `Q | Oct` pair).
- **Layer chips gated on content:** the whole `CanvasLayerChipStrip` is hidden
  until the ear has bands or an audiogram (or a live dynamics trace); its
  Output / Input / Result-EQ / Safety chips take a `hasContent` flag so they
  don't present dead toggles on an empty surface. Graphic passes the default
  (always content).

---

### 5.10 Tone Finder

Lives inside the Tinnitus Notch view in the main window — Tone Finder and notch
controls share one screen so the user reads identify-then-dial as one task.

The screen is organised as a **four-step guided flow** (level → sweep → compare
→ use) so pitch matching, notch configuration, and the symptom check-in read as
distinct jobs rather than one long form:

- **Step 1 — level:** Play/Stop transport (prominent red **Stop** while playing)
  + volume row. Sine-tone generator (`SineToneGenerator`) routed directly into
  `mainMixerNode` upstream of master gain, bypassing per-ear EQ so the reference
  pitch isn't coloured by the profile. The generator also serves the Listening
  Check via a per-channel mask (single-ear presentation) and a pulsed mode
  (200 ms on/off, 5 ms raised-cosine edges — sample-accurate in the render block).
- **Step 2 — sweep:** large frequency readout (Hz) + note approximation, drag to
  sweep (log scale, **1 kHz – 16 kHz**), and a **Step-size selector** (1 / 10 /
  100 Hz) with large **−** / **+** controls (replaced the six fixed-increment
  buttons).
- **Step 3 — compare:** "a bit lower / higher" nudges + octave down/up, plus an
  optional *Average a few matches* aid (capture → average/range).
- **Step 4 — use this pitch:** the **"Use this pitch"** action (renamed from
  "Set as Notch Frequency") writes the current tone into the active profile's
  notch and flips it on; with `separateNotch` on, the user picks Left / Right /
  Both. Applying briefly **highlights the notch card** so cause and effect read
  as connected.
- **Notch filter:** collapsed to a preview + **Enable at N Hz** button when off
  (no greyed-out form); when on, shows the preview, a Strength-first control, and
  a **Fine-tune notch** disclosure for depth/width. A hint offers to snap the
  notch to the finder pitch if the two drift apart.
- **Symptom check-in** is separated into its own **sheet** (opened from a footer
  button) — it tracks, it doesn't configure the processor.
- Non-clinical copy throughout.

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
│  Each ear's render-block chain, in order (phase-4 §4.1):               │
│    Stage-A cascade: AutoEQ correction (+ AutoEQ preamp)                │
│    → AdaptiveCorrectionProcessor (6-band level-following WDRC —        │
│      active only for `.adaptive` profiles; the filterbank IS the       │
│      correction in that mode)                                          │
│    → Stage-B cascade: steady correction (when `.steady`) + profile     │
│      EQ bands + tinnitus notch (+ global trim)                         │
│    → DynamicBandProcessor (Adaptive Comfort)                           │
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
- `@Published private(set) var autoEQMismatch: AutoEQMismatch?` — headphone
  correction running on a device it wasn't attached on (§5.7);
  `dismissAutoEQMismatch()` / `bypassAutoEQForSession()` are the two actions.
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
    var eqMode: EQMode                              // .advanced (Graphic) / .expert (Parametric)
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

enum EQMode: String, Codable, CaseIterable { case advanced /* Graphic */, expert /* Parametric */ }
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

The 5-second surface: a status dashboard and remote for *today's listening
session*, not a compressed copy of the app. Dismisses on click-outside. No
charts, canvases, or configuration.

```
┌──────────────────────────────────────────┐
│  SherlockEQ            [device label]    │
│  ● Processing Afternoon – AirPods        │  ← status: profile / Reference /
├──────────────────────────────────────────┤    pass-through
│  [ NoticeBanner (when active) ]          │
│  Output level  L ▓▓▓▓▓░░  R ▓▓▓▓░░       │  ← waiting state when no audio
│  Session  ████████░░░░  67%  ~1h 20m     │  ← dose bar + exposure status
│  Gain    ─────●─────── −2.3 dB    ↺      │
│  Balance ──────●────── Center     ↺      │
├──────────────────────────────────────────┤
│  Profile  [ Afternoon – AirPods    ▾ ]   │
│  [        🔴 Reference Mode         ]    │
│  ▸ Processing details                    │  ← collapsed status rows: Hearing
├──────────────────────────────────────────┤    adjustment / comfort / notch
│  Open Main Window                        │
│  Health & Safety                         │
│  Quit SherlockEQ                         │
└──────────────────────────────────────────┘
```

Controls the popover deliberately does **not** have: the adjustment-strength
slider and the tinnitus-notch toggle became the read-only "Processing details"
status rows — specialist configuration lives in the main window, and a
glanceable surface shouldn't offer knobs whose effect it can't show. The
level/dose rows tick at 1 Hz off a throttled tracker subscription.

On first appearance the popover calls `audioState.startAll()` so users don't have
to dig into Debug to bring the tap up.

Open Main Window (and the Health & Safety row, after setting the sheet flag)
hands off to `AppDelegate.showMainWindow`, which owns the NSWindow and
sequences the `.accessory → .regular` policy flip + activation
deterministically.

---

### 8.3 Main Window (default 1480 × 880pt, minimum 1126 × 716pt — width minimum 1387pt while the monitor panel is open — resizable)

`NavigationSplitView` with a left sidebar (fixed 240pt), detail content in the
middle (min 760 / ideal 820pt), and a persistent right monitor sidebar (260pt)
toggleable from the toolbar. The window minimum width follows the panel:
1126pt closed, 1387pt open, so opening the panel never crushes the detail
column below its slider-friendly width.

**Sidebar groups** (`SidebarView`):

- **Audio Processor** — Audiogram, Equalizer, Tinnitus Notch, Adaptive Comfort, Safe Listening
- **App** — Health & Safety Info (opens the disclosure sheet; not a
  navigation destination), Settings, Debug
- Bottom safe-area inset: the active-profile button alone (name + chevron;
  selects the Profiles section). Profiles is reachable via this shortcut, not
  from the section list, to avoid a duplicated top+bottom entry.

**Profiles** — master/detail. The list column's toolbar is a labeled **New
Profile** button plus a **More** overflow menu (duplicate / delete / import /
export / restore-factory) — replacing the old row of bare icons. Each row shows
name, a quiet built-in star, description, and linked device. **Status signals
are exactly two, non-competing**: the row's selection highlight means *being
edited*, and a single green **Active** pill means *currently processing audio*
(the old green dot + duplicate footer are gone). The detail panel opens with a
**scannable summary** (output device · headphone correction · hearing profile ·
EQ surface · per-ear) and the header distinguishes **"Editing"** from a green
**"Processing audio now"** pill. The long form is broken into **collapsible
groups** — Identity · Device and headphones · Hearing personalization · Sound
tuning · Safety — with specialist knobs (**Compensation, Global trim,
separate-ear**) under an **Advanced tuning** disclosure. Headphone correction
stays a compact **"None · Find my headphones…"** until the user opens the
search/library; once applied, the search moves behind a "Change headphones"
disclosure. Hearing personalization shows correction status + an **Edit
audiogram** deep-link (thresholds are edited on the Audiogram screen). The four
factory presets (§5.8) are fully editable; they show a banner with "Reset to
Factory Default" (enabled once edited) and Duplicate.

**Audiogram** — interactive audiogram chart for the active profile (Left ear / Right
ear tabs). Draggable threshold points at standard frequencies plus numeric entry
alongside. EQ preview rendered below.

**Equalizer** — shows the single EQ surface that matches the active profile's
`eqMode`, switched by a **Graphic | Parametric** segmented control in the
screen's toolbar (next to the title — the switch swaps this entire screen, so
the control lives where its effect is; it previously hid on Profile Detail).
The two surfaces:
- *Graphic* — 12-band graphic EQ on the audiometric grid (31.5, 63, 125, 250,
  500, 1k, 2k, 3k, 4k, 6k, 8k, 16k Hz — the octave series plus the 3 & 6 kHz
  audiogram frequencies; canonical list: `EQMode.graphicCenters`). Off-grid
  bands (from Parametric, the retired Simple/Speech modes, or the CLI's
  `simple-eq` slots) appear in an **"Other filters" row**: the response curve
  always includes them, and the row offers **Convert to Graphic** (a damped
  fixed-point fit of their composite response onto the 12 bells —
  `GraphicConversion`; one undo step) or **Edit in Parametric**. Nothing
  active is ever invisible.
- *Parametric* — full parametric canvas (draggable nodes, biquad curve, spectrum
  underlay, layer chip strip, AutoEQ + audiogram + safety overlays, L/R link)

Switching surfaces is non-destructive: bands stay in storage either way.

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

**Settings** (`SettingsView`) — collapsible groups; everyday preferences open,
DSP/engineering collapsed:
- **General** (open) — Launch at login; Hide from Dock when window is closed
- **Appearance** (open) — Per-ear colors (left / right)
- **Keyboard** (open) — Global ⌘⇧B Reference Mode shortcut (subtitle explains it
  temporarily bypasses all processing)
- **Advanced Audio** (collapsed) — **App master gain** (the app-wide value, the
  same control shown on the monitor panel — scope stated in place) + Peak
  limiter (AUPeakLimiter attack / decay / pre-gain)
- **Files and data** (collapsed) — Profiles folder (Move existing / Switch only
  prompt) + Headphone correction library folder (shared by every profile's
  headphone picker)
- **Diagnostics** (collapsed) — Show Debug in sidebar; Show metadata on profiles
- **About** — Acknowledgments (AutoEQ, NIOSH, Sparkle, open-source credits)

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
│   ├── TapMuteSentinel.swift               ← crash-resilient recovery of the tap's output mute
│   ├── SherlockEQAudioEngine.swift         ← AVAudioEngine graph, balance, limiter, gain
│   ├── BiquadCoefficients.swift            ← Audio EQ Cookbook coefficient math
│   ├── BiquadCascade.swift                 ← Per-ear render-block cascade
│   ├── BiquadResponse.swift                ← Magnitude response for curve drawing
│   ├── SpectrumAnalyzer.swift              ← vDSP DFT, A-weighting, dBA conversion
│   ├── StereoMonitor.swift                 ← L/R peak metering for the monitor surfaces
│   ├── VUMeter.swift                       ← Analog VU ballistics
│   ├── AudiogramConversion.swift           ← dB HL → EQBand
│   ├── AcclimatizationRamp.swift           ← 60→100 % over 21 days (§5.2)
│   ├── AdaptiveFilterbank.swift            ← 6-band LR4 compensated cascade (phase 4)
│   ├── AdaptiveCorrectionPrescription.swift ← NAL-R-anchored level-gain rule (phase 4)
│   ├── AdaptiveCorrectionProcessor.swift   ← Per-ear WDRC stage (phase 4)
│   ├── CorrectionConflict.swift            ← Notch ↔ correction collision check (§5.3)
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
│   ├── GraphicConversion.swift             ← Off-grid filters → 12-band graphic fit
│   └── GlobalHotKey.swift                  ← Carbon RegisterEventHotKey wrapper (⌘⇧B)
│
├── State/
│   ├── AudioState.swift                    ← Top-level ObservableObject composing all sub-state
│   ├── EQChainState.swift                  ← referenceMode + per-stage bypass toggles
│   ├── EngineParameters.swift              ← masterGain + limiter knobs
│   ├── AppPreferences.swift                ← Per-ear colors, dock, launch-at-login, hotkey
│   ├── AutoEQPreferences.swift             ← AutoEQ library folder
│   ├── AdaptiveActivityMonitor.swift       ← 15 Hz adaptive-gain telemetry for canvases (phase 4)
│   ├── NoticeCenter.swift                  ← Shared notice banner state
│   ├── NotificationManager.swift           ← UNUserNotificationCenter wrapper
│   └── SafeListeningTracker.swift          ← NIOSH dose accumulator
│
├── Models/
│   ├── HearingProfile.swift                ← incl. EQMode enum
│   ├── EarProfile.swift
│   ├── ListeningCheckSession.swift         ← Hughson–Westlake state machine (§5.2)
│   ├── AudiogramPoint.swift
│   ├── EQBand.swift                        ← incl. EQFilterType enum
│   ├── AutoEQMismatch.swift                ← Correction ↔ output-device mismatch (§5.7)
│   ├── PresetCurve.swift                   ← Shared outcome-preset curve table (§5.8)
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
│   │   ├── MainWindowView.swift            ← NavigationSplitView + sliding monitor panel + toolbar status glance
│   │   ├── Sidebar/
│   │   │   ├── SidebarView.swift
│   │   │   └── SidebarSection.swift        ← Sound / Comfort & Safety / App groups; toneFinder titled "Tinnitus Tools"
│   │   ├── Profiles/
│   │   │   ├── ProfilesView.swift
│   │   │   ├── ProfileListItem.swift
│   │   │   ├── ProfileDetailView.swift
│   │   │   └── AutoEQSearchView.swift      ← Remote catalog search + import
│   │   ├── Audiogram/
│   │   │   ├── AudiogramView.swift
│   │   │   ├── ListeningCheckView.swift    ← Guided threshold-estimate flow (§5.2)
│   │   │   ├── AudiogramChartView.swift
│   │   │   ├── ThresholdEditor.swift
│   │   │   ├── EQPreviewView.swift
│   │   │   └── AdaptivePreviewView.swift   ← 50/65/85 dB correction family (phase 4)
│   │   ├── Equalizer/
│   │   │   ├── EqualizerView.swift         ← Switches on profile.eqMode
│   │   │   ├── GraphicEQView.swift         ← 12-band graphic surface + "Other filters" row
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
│       ├── AutoEQMismatchRow.swift         ← Mismatch warning row (popover + Equalizer)
│       ├── CorrectionConflictChip.swift    ← Notch/correction conflict chip (§5.3)
│       ├── AcclimatizationChip.swift       ← Ramp status + skip (§5.2)
│       ├── NoticeBannerView.swift
│       ├── BuiltInProfileBanner.swift
│       ├── EQBypassButton.swift
│       ├── EQGainChip.swift
│       ├── CanvasLayerChipStrip.swift
│       ├── ScopeBadge.swift                 ← control-scope pill (App / Profile / Device / ear / Today)
│       ├── HealthSafetySheet.swift          ← consolidated Health & Safety disclosure sheet
│       ├── SafetyNote.swift                 ← contextual just-in-time safety notice
│       ├── LogFreqAxis.swift
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
| Window sizing | ✅ Resolved: the right monitor panel is now collapsed by default (a slide-in trailing column), so the minimum dropped from 1366 to 1126 pt (its former 240 pt gutter). The Expert layer-chip strip still fits without the panel; opening it may transiently compress the detail on a minimum-width window. |
