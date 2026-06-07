# SherlockEQ — Specification
**Name:** SherlockEQ
**Type:** macOS hybrid app — menu bar popover + full main window
**Target OS:** macOS 14.2 (Sonoma) and later
**Language:** Swift 5.9+ / SwiftUI
**Build tool:** Xcode 15+
**Audio:** Core Audio Taps + AVAudioEngine + AVAudioUnitEQ (AUNBandEQ)

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
music feels wrong. Needs independent left/right channel correction.

**The Podcast Prosumer**
Hosts or edits a personal or semi-professional podcast. Monitors audio during editing
and recording. Needs confidence that what they're hearing accurately reflects what
listeners hear. Uses bypass/reference mode to A/B their mix against their hearing profile.

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

---

## 4. UI Surface Map

This is the architectural decision that shapes everything else. SherlockEQ has two surfaces
with a clean division of responsibility.

### Menu Bar Popover (~380pt wide)
The popover is for **operating** SherlockEQ, not configuring it. It is what you interact
with a dozen times a day without thinking. It dismisses when you click away.

What belongs here:
- Active profile name + quick profile switcher
- Session dose bar and remaining time estimate
- Compensation strength slider (the one knob that matters most)
- Tinnitus notch on/off toggle
- Reference mode button (prominent, hold or click)
- Output device picker
- "Open SherlockEQ" button → opens the main window

What does NOT belong here:
- Audiogram entry
- Parametric EQ canvas
- Spectrum analyzer
- Tone Finder
- Profile creation or editing
- Settings

### Main Window (~860 × 600pt, resizable)
The window is for **configuring** SherlockEQ. It is opened deliberately. It appears in the
Dock and CMD+Tab while open. It has a sidebar-based navigation modeled on System
Settings — clear sections, no nested sheets required for primary tasks.

What belongs here:
- All profile management (create, edit, delete, reorder, import/export)
- Audiogram entry (interactive chart — needs real estate)
- Advanced and parametric EQ views with spectrum analyzer
- Tone Finder (focused task, dedicated view)
- Safe Listening detail and history
- All Settings
- Onboarding wizard (first launch only)

### Activation Policy
- Window closed → `NSApp.setActivationPolicy(.accessory)` — lives in menu bar only,
  no Dock icon, not in CMD+Tab
- Window open → `NSApp.setActivationPolicy(.regular)` — Dock icon appears, CMD+Tab
  works, feels like a full app
- This is the same pattern used by Fantastical, 1Password, iStat Menus, and others.

---

## 5. Feature Set

### 5.1 Hearing Profile System (Core)

A **Hearing Profile** is the central data object. Users can create and name multiple
profiles — one per output device, per context, or per activity.

Each profile contains:
- Display name and optional icon (SF Symbol)
- Left ear EQ curve (up to 16 bands)
- Right ear EQ curve (up to 16 bands, independent)
- Tinnitus notch settings (on/off, frequency, depth, Q)
- Global gain trim (±12 dB, prevents clipping after EQ boosts)
- Safe listening ceiling (user-set, default 85 dB)
- Creation date and last modified date
- Optional: linked output device (auto-activates when device connects)

Profiles are stored as JSON in `~/Library/Application Support/SherlockEQ/profiles/`.
Optional iCloud Drive sync via `NSUbiquitousKeyValueStore` (lightweight, for v2).

---

### 5.2 Audiogram Import

The most powerful onboarding path. The user enters their audiogram data — the numbers
from a printed or digital report from their audiologist. Lives in the main window.

**Standard audiogram frequencies (Hz):**
`250, 500, 1000, 2000, 3000, 4000, 6000, 8000`

**Entry method:** An interactive chart with draggable threshold points per ear.
Alternatively, numeric entry fields for each frequency/ear combination.
Values entered in **dB HL** (hearing level, as reported on audiograms).

**Conversion to EQ:**
- dB HL is the threshold relative to average normal hearing — it directly represents
  the additional gain needed at each frequency for audibility
- EQ boost at each frequency = `audiogram_loss_dBHL * compensation_factor`
- Default `compensation_factor` = 0.5 (partial compensation, conservative)
- Hard ceiling: no single band boosted more than **+20 dB** regardless of loss
- User adjusts `compensation_factor` (0.25–1.0) via the "Compensation Strength"
  slider — in both the popover (quick) and the window (in context with the EQ curve)
- Bands between audiogram frequencies are interpolated using cubic spline

**Caveat messaging (non-clinical):**
> "For losses above 40 dB, an EQ alone may not fully restore clarity — a hearing
> professional can discuss additional options. SherlockEQ is not a substitute for hearing aids."

**Per-ear independence:**
Left and right ears are configured separately. Most hearing loss is asymmetric. The
audio engine splits stereo to two parallel EQ chains (see Section 7).

---

### 5.3 Tinnitus Notch Filter

A narrow frequency cut applied at the user's tinnitus pitch. Research on tailor-made
notch training (TMNT) shows that sustained reduction of stimulation around the tinnitus
frequency can reduce perceived loudness over time.

**SherlockEQ makes no therapeutic claims.** The notch filter is presented simply as a way
to reduce the presence of frequencies that are already mentally fatiguing to the user.

**Popover:** On/off toggle + frequency label only.
**Main window (EQ view):** Full controls — frequency, depth (-3 to -15 dB), width
(Narrow / Medium / Wide, mapping to Q ~8 / ~4 / ~2). The notch is rendered as a
visible notch on the EQ curve in the parametric canvas.

---

### 5.4 Safe Listening Monitor

SherlockEQ estimates output loudness using FFT analysis on the post-EQ audio stream and
tracks a session dose based on NIOSH's 3 dB exchange rate standard:

| Level (dBA) | Safe Duration |
|-------------|--------------|
| ≤ 70        | Unlimited     |
| 80          | ~8 hours      |
| 85          | ~2.5 hours    |
| 88          | ~1.25 hours   |
| 91          | ~37 minutes   |
| 94          | ~18 minutes   |
| 100         | ~4 minutes    |

**Popover:** Compact dose bar (green → amber → red), remaining time label.

**Main window (Safe Listening view):** Full detail — current level estimate, session
history chart, per-day dose log, ceiling configuration, notification preferences.

**Behavior:**
- At 80% of daily dose: amber indicator in popover + menu bar icon tint, optional
  system notification
- At 100%: red indicator, system notification: *"You've reached your safe listening
  limit for today. Consider taking a break."*
- Dose resets at midnight or after a configurable quiet period (default 2h silence)

**Important framing:**
This is an *estimate* based on digital signal level, not a calibrated SPL meter.
Actual SPL at the ear depends on headphone type, fit, and hardware output level.
A one-time disclaimer is shown in onboarding and available in the Safe Listening view.

---

### 5.5 Reference Mode

A momentary bypass. Hold (or click-to-toggle) to instantly hear unprocessed system
audio for A/B comparison. Implemented as a single `bypass` flag on all EQ nodes —
no graph reconfiguration, no audio dropout.

**Popover:** Prominent Reference button, always visible.
**Main window:** Reference button also present in the EQ view toolbar.
**Global shortcut:** User-assignable in Settings.
**Menu bar icon:** Optional state change (e.g., dim or alt icon) while engaged.

---

### 5.6 Device Profiles & Auto-Switching

Any profile can be linked to a specific output device by name. When that device becomes
the default output, its profile activates automatically. "Passthrough" is a valid
profile (no EQ, monitoring only).

**Popover:** Device picker + current profile name show the active state.
**Main window (Profiles view):** Manage all device links, set priority order for
conflicts (two profiles linked to same device).

---

### 5.7 AutoEQ Integration

Import headphone correction curves from the AutoEQ project. The correction is applied
as a separate `AVAudioUnitEQ` node upstream of the hearing profile EQ:

```
System Audio → [AutoEQ Headphone Correction] → [Hearing Profile EQ] → Output
```

Both nodes can be toggled independently. AutoEQ curves are imported from plain-text
`.txt` filter files in AutoEQ parametric format.

**Main window only** — import, manage, and preview AutoEQ curves in the EQ view.

---

### 5.8 Voice Clarity Preset

A built-in profile preset targeting speech intelligibility for podcast monitoring.

| Frequency | Gain  | Rationale                              |
|-----------|-------|----------------------------------------|
| 500 Hz    | +1 dB | Vowel body warmth                      |
| 1000 Hz   | +2 dB | Fundamental speech intelligibility     |
| 2000 Hz   | +3 dB | Consonant clarity (primary zone)       |
| 3000 Hz   | +4 dB | Sibilance and plosive articulation     |
| 4000 Hz   | +3 dB | Presence and definition                |
| 6000 Hz   | +1 dB | Air and brightness                     |

Applied on top of or instead of the hearing profile EQ. Available as a named preset
in the Profiles list, not buried in a menu.

---

### 5.9 Parametric EQ (Expert View)

The full-control surface. Lives in the main window, EQ section, Expert tab.

- Interactive frequency response canvas: log-scaled x-axis (20Hz–20kHz), ±24 dB y-axis
- Draggable nodes: x = frequency, y = gain
- Right-click a node → change filter type (parametric, low/high shelf, notch, low/high pass)
- Q / bandwidth: pinch gesture or modifier-drag
- Composite EQ curve rendered in real time via SwiftUI `Canvas` and `Path`, computed
  from biquad coefficients (Audio EQ Cookbook formulas)
- Spectrum analyzer (80pt tall) drawn beneath the EQ curve using `vDSP` FFT
- Tinnitus notch rendered as a labeled notch on the curve
- L and R curves displayed simultaneously in different colors, with a toggle to edit
  each independently

---

### 5.10 Tone Finder

A dedicated view in the main window for identifying tinnitus frequency.

- Large frequency display (Hz) + musical note name approximation
- Sine tone generator at a safe, fixed output level (~60 dB estimated)
- Large drag/swipe target to sweep frequency (log scale, 1kHz–16kHz)
- Fine-tune stepper for ±1 Hz precision
- "Set as Notch Frequency" button — populates the tinnitus notch filter and returns
  to the EQ view
- Non-clinical copy throughout: *"Drag to find the pitch closest to your ringing."*

---

## 6. What Is Explicitly Out of Scope

- Per-application volume routing (requires a virtual driver)
- Recording / capture to file
- Virtual output devices
- MIDI or hardware control surfaces
- iOS / iPadOS companion (future, not now)
- Multichannel / surround audio (stereo only)
- Any clinical diagnostic feature

---

## 7. Technical Architecture

### 7.1 Audio Signal Path

```
┌─────────────────────────────────────────────────────────────────┐
│                        AVAudioEngine                            │
│                                                                 │
│  CATap ──► StereoSplitter ──► [Left EQ Chain]  ──► Mixer ──►  │
│                           └──► [Right EQ Chain] ──►           │
│                                                                 │
│  Left EQ Chain:  AutoEQ Node ──► HearingProfile Node ──► Trim │
│  Right EQ Chain: AutoEQ Node ──► HearingProfile Node ──► Trim │
│                                                                 │
│  Mixer ──► SpectrumTap ──► OutputNode                          │
└─────────────────────────────────────────────────────────────────┘
```

**StereoSplitter:** An `AVAudioMixerNode` routing L to the left chain and R to the
right chain. Each chain processes its channel independently.

**Tinnitus Notch:** A high-Q band inside the HearingProfile EQ node, not a separate
node — keeps the graph simple and the notch visible on the EQ curve.

**SpectrumTap:** `engine.mainMixerNode.installTap(onBus:)` captures post-EQ PCM
buffers. `vDSP_DFT_Execute` (Accelerate) computes the FFT. Results feed both
`SpectrumView` and `SafeListeningTracker`.

**Reference Mode:** Sets `.bypass = true` on all EQ nodes simultaneously. Glitch-free,
no graph reconfiguration.

---

### 7.2 CATapEngine

```swift
@available(macOS 14.2, *)
class CATapEngine: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var permissionGranted: Bool = false
    var sourceNode: AVAudioSourceNode?

    func requestPermissionAndStart() async { ... }
    func handleOutputDeviceChange(newDeviceID: AudioDeviceID) { ... }
    func stop() { ... }
}
```

- Tap targets all processes on the default output device
- Device change listener (`kAudioHardwarePropertyDefaultOutputDevice`) tears down
  and restarts the tap cleanly, then fires the profile auto-switch logic
- On permission denial: posts a notification that triggers an alert in whichever
  surface is visible (popover or window) with "Open System Settings" button

---

### 7.3 AudioState (ObservableObject)

Single source of truth, injected at the top of both the popover and window hierarchies
via `@EnvironmentObject`.

```swift
class AudioState: ObservableObject {
    // Profiles
    @Published var profiles: [HearingProfile] = []
    @Published var activeProfile: HearingProfile?

    // Engine state
    @Published var tapRunning: Bool = false
    @Published var referenceMode: Bool = false
    @Published var outputDevice: AudioDevice?

    // Safe listening
    @Published var sessionDosePercent: Double = 0
    @Published var currentLeveldBSPL: Double = 0
    @Published var remainingMinutes: Double?

    // Spectrum (updated ~30fps from vDSP)
    @Published var spectrumBins: [Float] = []

    // Persistence
    func saveProfiles()
    func loadProfiles()
}
```

---

### 7.4 Data Models

```swift
struct HearingProfile: Codable, Identifiable {
    var id: UUID
    var name: String
    var symbol: String                          // SF Symbol name
    var linkedDeviceUID: String?

    var leftEar: EarProfile
    var rightEar: EarProfile
    var notch: TinnitusNotch
    var globalTrimDB: Double                    // -12 to +12
    var autoEQCurveURL: URL?
    var safeListeningCeilingDB: Double          // default 85.0
    var compensationFactor: Double              // 0.25 to 1.0
}

struct EarProfile: Codable {
    var thresholds: [AudiogramPoint]            // [(hz: Int, dBHL: Double)]
    var bands: [EQBand]                         // computed from thresholds
}

struct AudiogramPoint: Codable {
    var frequencyHz: Int                        // 250, 500, 1000, 2000, 3000, 4000, 6000, 8000
    var thresholddBHL: Double                   // 0–110, from audiologist report
}

struct EQBand: Codable {
    var frequencyHz: Double
    var gaindB: Double
    var bandwidth: Double                       // Q value
    var filterType: EQFilterType
    var enabled: Bool
}

struct TinnitusNotch: Codable {
    var enabled: Bool
    var frequencyHz: Double                     // 1000–16000
    var depthdB: Double                         // -3 to -15
    var qWidth: NotchWidth                      // .narrow, .medium, .wide
}
```

---

### 7.5 Safe Listening Calculation

NIOSH equal energy (3 dB exchange rate):

```swift
func updateDose(currentLeveldBA: Double, elapsedSeconds: Double) {
    // NIOSH REL: 85 dBA = 8 hours = 28800 seconds
    let permissibleDuration = 28800.0 / pow(2.0, (currentLeveldBA - 85.0) / 3.0)
    sessionDose += elapsedSeconds / permissibleDuration  // fraction; 1.0 = 100%
}
```

Level estimate: RMS of post-EQ FFT spectrum, A-weighted per-bin using standard
A-weighting coefficients. Called at ~1 Hz from the analysis loop.

---

## 8. UI Structure

### 8.1 Menu Bar

- Icon: `waveform.and.magnifyingglass` or a custom waveform-with-notch asset
- Tinted amber or red when dose warning is active
- Left-click: open/close popover
- Right-click: quick menu — active profile name, Reference Mode toggle, Open SherlockEQ,
  Quit

---

### 8.2 Main Popover (~380pt wide)

The 5-second surface. Dismisses on click-outside. Never shows charts or canvases.

```
┌──────────────────────────────────────────┐
│  ≋ SherlockEQ        [AirPods Pro ▾]  [↗]  │  ← [↗] opens main window
├──────────────────────────────────────────┤
│  Session  ████████░░░░  67%  ~1h 20m    │  ← dose bar
├──────────────────────────────────────────┤
│  Profile  [ Afternoon – AirPods    ▾ ]  │
│                                          │
│  Compensation   ○————————●————————○     │  ← single slider
│                 Less              More   │
│                                          │
│  Tinnitus Notch  ●—— ON   4,200 Hz      │
│                                          │
│  [        🔴 Reference Mode         ]   │  ← prominent, hold or toggle
└──────────────────────────────────────────┘
```

The "Open SherlockEQ" button (↗) in the header opens the main window and brings it to
front. If the window is already open, it focuses it.

---

### 8.3 Main Window (~860 × 600pt minimum, resizable)

Sidebar-based navigation modeled on System Settings. The sidebar is always visible.
Content area changes based on the selected section.

```
┌─────────────────┬─────────────────────────────────────────────────┐
│  LIBRARY        │                                                 │
│  ──────────     │                  [content area]                 │
│  👤 Profiles    │                                                 │
│  👂 Audiogram   │                                                 │
│  🎛  Equalizer  │                                                 │
│  🔔 Tone Finder │                                                 │
│  📊 Safe Listen │                                                 │
│  ⚙️  Settings   │                                                 │
│                 │                                                 │
│  [+ New Profile]│                                                 │
└─────────────────┴─────────────────────────────────────────────────┘
```

**Sidebar sections:**

**Profiles**
List of all profiles. Click to select and make active. Toolbar: add, duplicate,
delete, import, export. Detail panel (right side of content area) shows profile name,
device link, icon picker, compensation factor, global trim, and safe listening ceiling.

**Audiogram**
Interactive audiogram chart for the active profile. Two panels: Left ear, Right ear
(tab or side-by-side toggle). Draggable threshold points at standard frequencies.
Numeric entry fields alongside the chart for exact values. The resulting EQ curve is
previewed in a smaller read-only curve below the chart.

**Equalizer**
Three-tab view for the active profile:

- *Simple* — 3-band (Bass / Mids / Treble) derived from the full curve. Friendly
  starting point for users who don't want to touch individual bands.
- *Advanced* — 10-band graphic EQ with vertical sliders. Shows L and R as separate
  columns when ears differ.
- *Expert* — Full parametric canvas (draggable nodes, biquad curve, spectrum
  analyzer). AutoEQ import/toggle. Tinnitus notch controls with the notch visible
  on the curve. L/R color-coded curves overlaid, individually editable.

Reference mode button is present in the Expert view toolbar for A/B comparisons
during detailed work.

**Tone Finder**
Full-width view with the large frequency sweep control, a waveform visualization of
the sine tone, fine-tune stepper, and the "Set as Notch Frequency" button. Includes
a brief non-clinical explanation of what the feature does and does not do.

**Safe Listening**
- Current level estimate (dBSPL, updated live)
- Session dose bar (large, detailed)
- Chart: dose history over the past 7 days
- Configuration: personal ceiling, warning threshold, notification preferences,
  dose reset behavior
- Explanatory section: what the dose estimate is, what it isn't, link to NIOSH REL

**Settings**
- Launch at login
- Global keyboard shortcut for Reference Mode
- Device auto-switching: on/off, manage linked device→profile pairs, priority order
- AutoEQ: import new curves, manage library, credit AutoEQ project
- Profile backup location (Application Support default or custom folder)
- About + acknowledgments (AutoEQ, NIOSH, open source credits)
- "Open Accessibility Settings" — links to macOS System Settings > Accessibility

---

### 8.4 Onboarding (First Launch)

Opens as a separate window (not a sheet over the main window). Covers:

1. **Welcome** — brief positioning statement, two paths:
   - "I have an audiogram" → wizard
   - "Set up manually" → opens main window at Profiles section

2. **Permission** — before any audio starts:
   > "SherlockEQ needs access to system audio to apply your hearing profile."
   > [Grant Access] → triggers macOS privacy sheet

3. **Wizard — Profile name + device link**

4. **Wizard — Left ear audiogram** (interactive chart)

5. **Wizard — Right ear audiogram** (pre-mirrored from left, user adjusts)

6. **Wizard — Tinnitus?** (Yes → Tone Finder inline; No → skip)

7. **Wizard — Safe listening ceiling** (slider, explanation of the NIOSH standard)

8. **Done** — "Your profile is active. SherlockEQ is running in your menu bar." Closes
   onboarding window, opens main window briefly to show the finished profile, then
   the main window can be dismissed.

---

## 9. Project File Structure

```
SherlockEQ/
├── SherlockEQApp.swift                      ← @main, WindowGroup, activation policy
├── MenuBarController.swift              ← NSStatusItem, NSPopover, right-click menu
│
├── Audio/
│   ├── CATapEngine.swift                ← Core Audio Taps, device change handling
│   ├── SherlockEQAudioEngine.swift          ← AVAudioEngine graph, L/R chains, bypass
│   ├── SpectrumAnalyzer.swift           ← vDSP FFT, A-weighting
│   ├── AutoEQParser.swift               ← Parse AutoEQ .txt → [EQBand]
│   └── ToneGenerator.swift             ← Sine sweep for Tone Finder
│
├── State/
│   ├── AudioState.swift                 ← ObservableObject, @Published
│   └── SafeListeningTracker.swift       ← Dose accumulator, timer, notifications
│
├── Models/
│   ├── HearingProfile.swift
│   ├── EarProfile.swift
│   ├── AudiogramPoint.swift
│   ├── EQBand.swift
│   └── TinnitusNotch.swift
│
├── Persistence/
│   ├── ProfileStore.swift               ← JSON save/load, Application Support
│   └── DevicePreferences.swift          ← Device→profile links
│
├── UI/
│   ├── Popover/                         ← Dismissable, 380pt, operations only
│   │   ├── MainPopoverView.swift
│   │   ├── DoseBarView.swift
│   │   ├── ProfilePickerRow.swift
│   │   ├── CompensationSliderView.swift
│   │   └── ReferenceButton.swift
│   │
│   ├── Window/                          ← Persistent, resizable, configuration
│   │   ├── MainWindowView.swift         ← NavigationSplitView root
│   │   ├── Sidebar/
│   │   │   └── SidebarView.swift
│   │   ├── Profiles/
│   │   │   ├── ProfilesView.swift       ← List + toolbar
│   │   │   └── ProfileDetailView.swift  ← Name, device, trim, ceiling
│   │   ├── Audiogram/
│   │   │   ├── AudiogramView.swift      ← L/R tab + chart + numeric fields
│   │   │   └── AudiogramChartView.swift ← Interactive draggable threshold chart
│   │   ├── Equalizer/
│   │   │   ├── EqualizerView.swift      ← Tab container (Simple/Advanced/Expert)
│   │   │   ├── SimpleEQView.swift       ← 3-band Bass/Mids/Treble
│   │   │   ├── AdvancedEQView.swift     ← 10-band graphic sliders, L/R columns
│   │   │   └── ExpertEQView.swift       ← Parametric canvas + spectrum + notch
│   │   ├── ToneFinder/
│   │   │   └── ToneFinderView.swift
│   │   ├── SafeListening/
│   │   │   └── SafeListeningView.swift  ← Detail, history chart, settings
│   │   └── Settings/
│   │       └── SettingsView.swift
│   │
│   ├── Onboarding/
│   │   ├── OnboardingWindowView.swift   ← Separate window, wizard steps
│   │   └── WelcomeView.swift
│   │
│   ├── Components/                      ← Shared across popover and window
│   │   ├── ParametricCanvasView.swift   ← Draggable EQ nodes, biquad curve
│   │   ├── SpectrumView.swift           ← vDSP FFT canvas
│   │   ├── BandSliderView.swift
│   │   ├── NotchControlView.swift
│   │   └── DevicePickerView.swift
│   │
│   └── Theme/
│       └── SherlockEQTheme.swift            ← Color, font, spacing tokens
│
└── Resources/
    ├── Assets.xcassets
    ├── Info.plist
    └── SherlockEQ.entitlements
```

---

## 10. Entitlements

```xml
<!-- SherlockEQ.entitlements -->
<key>com.apple.security.device.audio-input</key>
<true/>
```

`Info.plist`:
```xml
<key>NSMicrophoneUsageDescription</key>
<string>SherlockEQ uses system audio access to apply your hearing profile to all apps on your Mac.</string>
```

No privileged helper. No driver installation. No password prompt.

---

## 11. Getting Started in Claude Code

```bash
# In Xcode: File > New > Project > macOS > App
# Product name: SherlockEQ
# Interface: SwiftUI
# Language: Swift
# Uncheck "Include Tests" for now
# IMPORTANT: In the target's Info.plist, set
#   "Application is agent (UIElement)" = YES
#   This suppresses the default Dock icon at launch;
#   MenuBarController manages activation policy dynamically.

cd ~/code/SherlockEQ
git init && git add . && git commit -m "initial xcode project"
claude
```

**Suggested build order:**

| Session | Surface   | Goal |
|---------|-----------|------|
| 1  | —          | `CATapEngine.swift` — permission, tap lifecycle, device change |
| 2  | —          | `SherlockEQAudioEngine.swift` — L/R EQ chains, bypass, connect to tap |
| 3  | —          | `Models/` — Codable structs, `ProfileStore`, JSON round-trip |
| 4  | Popover    | `MenuBarController` + `MainPopoverView` — popover opens, dose bar placeholder |
| 5  | Popover    | `CompensationSliderView`, `ReferenceButton`, profile switcher — wired to `AudioState` |
| 6  | Window     | `MainWindowView` + `SidebarView` — `NavigationSplitView` skeleton, all sections present |
| 7  | Window     | `ProfilesView` + `ProfileDetailView` — CRUD, JSON persistence |
| 8  | Window     | `AudiogramChartView` + conversion logic (audiogram → EQ bands) |
| 9  | Window     | `SimpleEQView` + `AdvancedEQView` — live band updates to engine |
| 10 | —          | `SpectrumAnalyzer` — vDSP FFT, A-weighting, dose integration |
| 11 | Popover    | `DoseBarView` wired to `SafeListeningTracker` — live in popover |
| 12 | Window     | `SafeListeningView` — full detail, history, configuration |
| 13 | Window     | `ParametricCanvasView` — biquad curve, draggable nodes, spectrum underlay |
| 14 | Window     | `ExpertEQView` — notch controls, AutoEQ toggle, L/R overlay |
| 15 | Window     | `ToneFinderView` — sine generator, sweep, "Set as Notch" |
| 16 | Window     | `OnboardingWindowView` — wizard flow, permission request |
| 17 | Both       | Device auto-switching, `SettingsView`, activation policy, polish |

**Suggested first Claude Code prompt:**
> "Create `Audio/CATapEngine.swift` in the SherlockEQ Xcode project. It should request
> system audio capture permission using `AVCaptureDevice.requestAccess(for: .audio)`,
> create a `CATapDescription` targeting all processes on the default output device,
> create a private aggregate device using `AudioHardwareCreateAggregateDevice`, and
> expose an `AVAudioSourceNode` for use by `AVAudioEngine`. Handle output device
> changes via a `kAudioHardwarePropertyDefaultOutputDevice` listener. Requires
> macOS 14.2+. Mark the class `@available(macOS 14.2, *)`."

---

## 12. Open Questions

| Item | Notes |
|------|-------|
| App name | "SherlockEQ" — name is set. Still confirm no App Store trademark conflicts before public release. |
| App Store distribution | Core Audio Taps requires `com.apple.security.device.audio-input` outside the App Store sandbox. Plan for notarized DMG distribution (same as eqMac). Worth a direct inquiry to Apple DTS about whether an entitlement exception is available. |
| dBHL → EQ accuracy | The 0.5× compensation factor is a pragmatic heuristic. A more rigorous v2 approach would apply ISO 226 equal-loudness correction to convert dBHL thresholds to dBSPL before deriving EQ gains. |
| Left/right EQ routing | Stereo split via `AVAudioMixerNode` requires verifying sample-accurate L/R alignment with no drift. Test during Session 2 with a phase-coherent mono test tone and confirm no comb filtering. |
| Spectrum analyzer accuracy | The dose estimate is only as accurate as the digital signal level. Hardware output gain, headphone impedance, and ear canal fit all affect actual SPL. One-time onboarding disclaimer is sufficient. |
| AutoEQ license | AutoEQ data is MIT licensed. Credit the project in Settings > About with a link to the repository. |
| Window sizing | 860 × 600pt is a reasonable minimum. The parametric EQ canvas benefits from wider windows. Consider setting a minimum width of 760pt and letting height be free. |
