# SherlockEQ — Dynamic EQ for Hearing Use Cases

**Feature:** Level-dependent EQ processors for speech presence, harshness control, and sibilance taming
**For:** Claude Code implementation session
**Scope:** New DSP stage (per-ear dynamic band processors), profile schema extension, new "Clarity" panel, Expert canvas activity overlay
**Status:** Specified, not yet scheduled
**Spec date:** 2026-06-09

---

## Design Notes (Read Before Implementing)

Four decisions are load-bearing. Understand them before touching code.

**1. Dynamic features follow the Tinnitus Notch pattern, NOT the EQ-band pattern.**
They are dedicated fields on `HearingProfile` (like `leftNotch`/`rightNotch`/`separateNotch`), folded into the audio path at `applyProfile` time, with their own sidebar panel. They are deliberately NOT stored in `EarProfile.bands`. Storing them as bands would entangle them with `EQMode.ownedSlots` slot ownership, `HiddenBandsHintChip` accounting, preset menus, AutoEQ import/combine logic, and `audiblyEquivalent(to:)` comparisons — none of which know what a threshold or attack time means. The notch proved the dedicated-field path works end-to-end (model → applyProfile fold → render block → own UI + canvas overlay).

**2. Expert mode gets read-only visualization in this phase. Editing is deferred.**
A new "Dynamics" layer chip shows live gain activity on the Expert canvas. Per-band dynamic *editing* in Expert is explicitly out of scope — it requires redesigning canvas node semantics (a node's y-position currently *is* its gain; a dynamic band's gain is a moving value), breaking the cached-EQ-curve perf optimization, and extending an already-full keyboard map. See §10 for the conditions under which that work should be revisited.

**3. Thresholds are adaptive, not absolute.**
SherlockEQ processes arbitrary system audio at unknown levels. An absolute dBFS threshold would behave differently on a quiet podcast vs. a loud movie. Each detector therefore computes its threshold relative to a slow (~3 s) rolling average of its own band energy; the user-facing Sensitivity slider sets the offset above that average. This makes the features level-independent and keeps them working without SPL calibration. (WDRC — true loudness-dependent correction — is the feature that *does* need calibration, and it is out of scope here; see §11.)

**4. Coefficient modulation on the audio thread is the riskiest engineering item.**
The static `BiquadCascade` computes coefficients on the main thread and treats them as immutable per snapshot. Dynamic bands must recompute their cookbook coefficients on the *render thread* as the envelope moves. This is pure math (no allocation, realtime-safe by construction), but it is a new invariant. It lives in a new sibling class — `DynamicBandProcessor` — rather than inside `BiquadCascade`, so the static cascade's contract stays untouched.

---

## 1. Background & Goals

The original architecture document (and `sherlockEQ-spec.md` §6's "future" list) names dynamic processing for hearing-assistance use cases: speech presence enhancement, harshness control, sibilance control. Static EQ can't serve these — a permanent 6 kHz cut dulls all program material to tame sibilance that is only present a few percent of the time. A dynamic band cuts (or boosts) only while the triggering content is actually present.

### Goals

- Three named, preconfigured dynamic processors a non-engineer can use: **Speech Presence**, **Harshness Control**, **Sibilance Tamer**.
- Each exposed as: enable toggle + Strength slider + Sensitivity slider + live activity indicator.
- Per-ear independence consistent with the rest of the app (mirrors `separateNotch` semantics).
- Zero added latency (time-domain processing in the existing render blocks).
- Visible proof-of-work: activity meters in the panel, live gain trace on the Expert canvas.
- Realtime safety equal to the existing cascade: no allocation, no unbounded locks, no blocking on the audio thread.

### Non-goals (this spec)

- WDRC / loudness-dependent audiogram correction (Phase C — separate spec; changes the app's safety posture because SPL calibration becomes load-bearing).
- Per-band dynamic editing in Expert mode (deferred — see §10).
- Raw threshold/ratio/attack/release controls anywhere in the UI (the named features map two sliders onto those internally).
- Popover controls (v1 ships main-window only; a popover "Clarity" toggle can come later if wanted).

---

## 2. The Three Features

All filters are Audio EQ Cookbook biquads via the existing `BiquadCoefficients` math, so drawn curves can never disagree with audio.

| | Speech Presence | Harshness Control | Sibilance Tamer |
|---|---|---|---|
| **Direction** | Boost (upward, gated) | Cut (downward) | Cut (downward) |
| **Main filter** | Bell @ 2.5 kHz, Q 0.9 | Bell @ 3.5 kHz, Q 1.4 | Bell @ 6.5 kHz, Q 2.0 |
| **Detector band** | 1.5–4 kHz band-pass | 2–5 kHz band-pass | 5–9 kHz band-pass |
| **Detector type** | RMS | RMS | Peak |
| **Attack** | 30 ms | 10 ms | 3 ms |
| **Release** | 300 ms | 150 ms | 80 ms |
| **Ratio (above knee)** | 1:2 expansion-style engage | 2:1 | 3:1 |
| **Knee** | 6 dB soft | 6 dB soft | 6 dB soft |
| **Max gain delta (Strength = 1.0)** | +6 dB | −8 dB | −10 dB |
| **Sensitivity range (offset above rolling avg)** | +3 … +15 dB | +3 … +15 dB | +3 … +15 dB |

Behavioral definitions:

- **Sibilance Tamer** — when peak energy in the 5–9 kHz detector band exceeds the adaptive threshold, the 6.5 kHz bell cuts proportionally (up to the Strength-scaled max). Fast attack so the leading edge of an "s" is caught; release short enough that the cut doesn't smear into following vowels.
- **Harshness Control** — same shape, slower and gentler, centered on the 2–5 kHz region where compression artifacts, shouty mixes, and hyperacusis-relevant energy live.
- **Speech Presence** — inverted logic: when sustained energy *is present* in the speech-formant detector band (i.e., someone is talking), the presence bell engages a boost; when the band is quiet (music interlude, ambience), the boost relaxes to zero. This is a gated boost, not an expander on the full signal — it must never amplify hiss in speech pauses. The slow attack/release keeps it from pumping on syllable boundaries.

**Tuning is expected.** Every number in the table is a starting point. Centers, Qs, and ballistics get finalized by listening tests (see §9.3). Keep them as named constants in one place (`DynamicFeatureKind` definitions, §4) so tuning is a one-file change — same convention as `conflictWindowOctaves` in the AutoEQ spec.

---

## 3. DSP Design

### 3.1 Placement in the signal path

Per ear, inside the existing `AVAudioSourceNode` render blocks in `CATapEngine.applyTapPrep`:

```
ring read → BiquadCascade.process (AutoEQ + bands + notch + trim, static)
          → DynamicBandProcessor.process (this feature)            ← NEW
          → preIngest side-channel / peak counters (unchanged)
          → AVAudioEngine graph: balance mixers → sum → AUPeakLimiter → master gain → output
```

Rationale:

- **After the static cascade** for the same reason the notch sits after AutoEQ correction (see the AutoEQ spec's "notch-after-correction" design note): the detector should see a tonally corrected signal, so feature behavior is consistent across headphones and profiles.
- **Before the side-channel callback and peak counters**, so every observer (pre-spectrum slot, debug peaks) sees what the user hears, consistent with the existing comment in the render block.
- **Upstream of AUPeakLimiter**, so the limiter remains the absolute safety net over any dynamic boost.
- The post-EQ spectrum tap on `mainMixerNode` is downstream of everything, so the **dose tracker automatically accounts for dynamic boost** — no changes to `SafeListeningTracker` needed.

### 3.2 `DynamicBandProcessor` (new, `Audio/DynamicBandProcessor.swift`)

One instance per ear, **owned by `CATapEngine`** alongside `leftEQCascade`/`rightEQCascade` (same reason: the render block must capture it strongly without an isolation hop). Same lifecycle: configured from the main thread, processed from the audio thread, survives graph rebuilds via reconfiguration.

Each processor hosts up to `maxFeatures = 3` **slots**, one per feature kind. Per slot, per render call:

1. **Sidechain detect** — run the slot's band-pass biquad over the (post-static-EQ) input into a scratch accumulation; compute peak or RMS per the feature's detector type. The sidechain reads the input *before* this slot's gain is applied (feed-forward), so the detector can't chase its own gain changes.
2. **Adaptive threshold** — maintain a slow one-pole average of the detector level (τ ≈ 3 s, dB domain). Threshold = average + sensitivity offset. Clamp the average's floor at −70 dBFS so silence doesn't drag the threshold into the noise and cause false triggers on resume.
3. **Envelope follower** — one-pole attack/release smoother in the dB domain on (detectorLevel − threshold), clamped at 0 below the knee.
4. **Gain computer** — soft-knee ratio curve mapping overshoot → target gain delta, clamped to the Strength-scaled max. Cut features produce negative deltas; Speech Presence maps detector engagement to a positive delta.
5. **Gain smoothing** — one-pole smoother (τ ≈ 5 ms) on the target delta to eliminate zipper noise.
6. **Coefficient update at block rate** — every `updateInterval = 64` samples, if the smoothed delta moved ≥ 0.1 dB since the last update, recompute the main bell's cookbook coefficients at the current delta and swap them into the slot's working section. Between updates, samples run through the current section unchanged.
7. **Process** — run the main bell (DF2T, identical recurrence to `BiquadCascade.Section`) over the buffer in place. A slot whose smoothed delta is < 0.1 dB **bypasses entirely** (no filter state pollution, no CPU) — at rest, the whole stage is near-free.

**Telemetry out:** after each render call, store each slot's current smoothed delta into an `AudioCounter` (milli-dB, signed) — the established atomics pattern. Six counters total (3 features × 2 ears), owned by the processor, sampled by the UI at display rate (§6.2).

### 3.3 Realtime-safety rules (all mandatory, all match existing precedent)

- Parameter handoff via `OSAllocatedUnfairLock` snapshot once per buffer — identical to `BiquadCascade.process`. Config struct is small POD; Array COW not even needed (fixed 3 slots).
- All detector/envelope/filter state pre-allocated at init; **zero heap activity on the audio thread**.
- Coefficient recompute is pure math (`BiquadCoefficients.cookbook`) — verify it stays allocation-free; it is today.
- State reset rules: zero all envelopes, averages, and filter state on (a) SR change, (b) slot enable/disable, (c) bypass toggle off→on transition. Same shape as the cascade's section-count memset.
- Denormal flush on the main-bell state once per buffer, matching `BiquadCascade`'s threshold (`1e-25`).
- Reference Mode bypass: `setBypassed(_:)` mirrors the cascade's — one flag read in the snapshot, early return.

### 3.4 Stability & quality requirements

- DF2T under per-block coefficient modulation with ≤ 0.1 dB steps and 5 ms gain smoothing is well-behaved; the test suite must prove it (§9.1): no NaN/Inf, no unbounded state, under worst-case modulation (square-wave bursts straddling the threshold at high Strength).
- Gain-step audibility: with smoothing as specced, per-update steps are ≤ ~0.1 dB — below audibility. If listening tests find zipper artifacts on pure tones, halve `updateInterval` before touching anything else.

### 3.5 CPU budget

Per active, *triggered* slot per sample: one sidechain biquad (~9 flops) + one main biquad (~9 flops) + envelope math amortized. Worst case (3 slots × 2 ears, all triggered): roughly 1.5–2× the current static cascade cost at typical band counts. At rest (no triggers): sidechain detectors only — a fraction of that. Acceptable without further optimization; do not vectorize preemptively.

---

## 4. Data Model

### 4.1 New types (`Models/DynamicFeature.swift`)

```swift
enum DynamicFeatureKind: String, Codable, CaseIterable {
    case speechPresence, harshnessControl, sibilanceTamer
    // Static metadata lives here: display name, SF Symbol, help text key,
    // and ALL DSP constants from §2's table (filter center/Q, detector band,
    // detector type, attack/release, ratio, knee, max delta, sensitivity range).
    // One file to tune.
}

struct DynamicFeatureSettings: Codable, Equatable {
    var enabled: Bool = false
    var strength: Double = 0.5      // 0…1 → scales max gain delta
    var sensitivity: Double = 0.5   // 0…1 → maps onto the feature's offset range (inverted: higher sensitivity = lower offset = triggers sooner)
}

struct DynamicProcessingSettings: Codable, Equatable {
    var leftSpeechPresence:  DynamicFeatureSettings = .init()
    var rightSpeechPresence: DynamicFeatureSettings = .init()
    var leftHarshness:       DynamicFeatureSettings = .init()
    var rightHarshness:      DynamicFeatureSettings = .init()
    var leftSibilance:       DynamicFeatureSettings = .init()
    var rightSibilance:      DynamicFeatureSettings = .init()
    /// Mirrors `separateNotch`: when false, the UI keeps L/R pairs in sync
    /// and shows one shared panel per feature.
    var separateChannels: Bool = false

    // Provide keyed accessors: settings(for kind:, ear:) -> DynamicFeatureSettings
    // and a mutating setter, so UI and engine code never switch over six fields.
}
```

### 4.2 `HearingProfile` extension

- New field: `var dynamics: DynamicProcessingSettings` — decoded with `decodeIfPresent`, defaulting to all-disabled (backward compatible, matches every prior schema addition).
- Built-in profile protection applies: the Clarity panel's editors are `.disabled(profile.isBuiltIn)` with the standard `BuiltInProfileBanner` duplicate-to-edit path.
- Export/import: rides along in the existing profile JSON automatically; `importProfile` needs no changes.
- Undo: edits flow through `ProfileStore.save`, inheriting the existing 500 ms-coalesced undo registration. Action name: "Edit \(profile.name)" (existing convention).

### 4.3 Strength/Sensitivity → DSP mapping

Both mappings live next to the constants in `DynamicFeatureKind`:

- `maxDeltaDB(strength)` = linear: `strength × featureMaxDelta` (e.g. Sibilance: 0…−10 dB).
- `thresholdOffsetDB(sensitivity)` = linear inverse across the feature's range: sensitivity 0 → +15 dB (triggers rarely), 1 → +3 dB (triggers readily).

---

## 5. Engine Integration

### 5.1 `CATapEngine`

- Owns `let leftDynamics = DynamicBandProcessor()`, `let rightDynamics = DynamicBandProcessor()` (peers of the cascades, declared adjacent).
- Render blocks call `lDyn.process(samples:count:)` / `rDyn.process(...)` immediately after the cascade `process` call, before the preIngest snapshot and peak recording.
- On `applyTapPrep`, pass the delivered sample rate into both processors (`setSampleRate(_:)`) so detector and filter coefficients are computed against the correct Nyquist — same moment the cascades' rate context is established.

### 5.2 `SherlockEQAudioEngine`

- `attach(...)` gains `leftDynamics:`/`rightDynamics:` parameters (weak refs stored, mirroring the cascade refs) so profile changes can push config.
- `applyProfile(_:)` adds one step: map `profile.dynamics` → per-ear slot configs (`kind`, `enabled`, `maxDeltaDB`, `thresholdOffsetDB`) and call `leftDynamics.configure(slots:)` / `rightDynamics.configure(slots:)`. Log line extends the existing applyProfile debug log with a dynamics summary (e.g. `dynamics: sib L+R 0.7, harsh off, speech L 0.4`).
- `flattenChain()` and `teardownGraph()` clear both processors to all-disabled (same stale-state reasoning as the cascade clears).
- `setReferenceMode(_:)` bypasses both processors alongside the cascades — Reference Mode means *truly* unprocessed.
- `setTestCurveEnabled(_:)` leaves dynamics untouched (the test curve is a static-path diagnostic).

### 5.3 `EQChainState` (per-stage bypass)

Add a `dynamicsBypassed` toggle following the existing per-stage bypass pattern, surfaced wherever the other stage bypasses live. AudioState sinks it reactively into the engine like the others.

---

## 6. UI Spec

### 6.1 "Clarity" panel (new sidebar section)

- **Sidebar:** new entry **Clarity** (SF Symbol: `waveform.badge.magnifyingglass` or `ear.badge.waveform` — pick whichever renders better at sidebar size) in the **Audio Processor** group, ordered after Tinnitus Notch.
- **File:** `UI/Window/Clarity/ClarityView.swift` (+ `DynamicFeatureCard.swift`).
- **Empty state:** no active profile → `ContentUnavailableView` matching the Equalizer screens' pattern.
- **Layout:** one card per feature, vertically stacked, each card containing:
  - Header row: feature name + SF Symbol + enable `Toggle` (switch style).
  - **Strength** slider (0–100 %), with reset button (existing per-row reset convention).
  - **Sensitivity** slider (0–100 %), with reset.
  - **Activity meter** (§6.2): a small horizontal bar + numeric readout showing the current gain delta, e.g. `−3.2 dB` while taming, `idle` at rest.
  - Help text: one `.callout`/`.secondary` paragraph per card (per the readability convention) explaining what the feature listens for and does. Sibilance card example: "Listens for sharp 'sss' energy and softens it only while it's present. Raise Strength for a deeper cut; raise Sensitivity to react to quieter sibilance." Include the not-a-hearing-aid framing once at the panel's footer, not per-card.
- **Separate L/R:** a panel-level toggle bound to `dynamics.separateChannels`, mirroring the Tinnitus Notch screen's behavior — off shows one shared card per feature (writes both ears), on shows stacked per-ear cards (reuse the `NotchControlView` overridable-title pattern; per-ear tinting from `AppPreferences` ear colors).
- **Built-ins:** standard `BuiltInProfileBanner` + disabled editors.

### 6.2 Activity meters

- Source: the six `AudioCounter` gain values from `DynamicBandProcessor` (§3.4), exposed via `AudioState` (or directly off `CATapEngine` like the debug counters).
- Sampling: 10–20 Hz `Timer` in `.common` mode, **subscriber-refcounted** so the loop only runs while a Clarity panel (or Expert dynamics overlay) is visible — same gating discipline as `StereoMonitor` and the spectrum analyzers. Do NOT publish through `AudioState.objectWillChange` (the 46 Hz rebroadcast lesson); meter views observe a small dedicated `ObservableObject` directly.
- Visual: bar fills from center/zero toward the cut or boost direction; numeric `%+.1f dB` readout. Non-color redundancy: the bar plus the number, and an `idle`/`active` text state — no color-only signaling (colorblind convention).

### 6.3 Expert canvas overlay ("Dynamics" layer)

- New chip in `CanvasLayerChipStrip`: **Dynamics**, persisted as `@AppStorage("sherlockeq.layer.dynamics")`, default ON, hidden/disabled when the active profile has no enabled dynamic features (same conditional pattern as the Audiogram chip's `hasAudiogram`).
- Rendering: for each enabled feature on the displayed ear, draw the main bell's *current* response contribution (computed via `BiquadResponse` from the live gain delta) as a separate animated stroke under the static EQ curve — visually distinct (dashed stroke per the redundant-pattern a11y convention), tinted with the ear color at reduced opacity.
- **Perf rules:** the static EQ curve cache is untouched. Only the dynamic contribution recomputes, only while the Dynamics chip is on, at the meter sampling rate (≤ 20 Hz), and only for slots whose delta exceeds 0.1 dB (at rest, nothing animates and nothing recomputes). Respect `accessibilityReduceMotion` by snapping rather than animating.
- The lens menu presets do not change in v1 (Dynamics participates as a manually toggled chip only).

### 6.4 Accessibility & localization (house conventions, all mandatory)

- Sliders are standard SwiftUI `Slider`s — VO-adjustable for free; give each an explicit `accessibilityLabel` including the feature name and ear.
- Activity meter: `.accessibilityElement(children: .ignore)` + composed label/value reading as one sentence ("Sibilance Tamer, currently reducing 3 decibels").
- All strings via `Text("...")` literals or `String(localized:)` so the String Catalog picks them up; numeric readouts via `FormatStyle`.
- No new error surfaces: any failure states route through `NoticeCenter` per `error-routing-through-noticecenter.md` (this feature should have none in practice — it has no I/O).

---

## 7. Safety

- **Boost ceiling:** Speech Presence max is +6 dB and is the only boosting feature. Combined with the AUPeakLimiter downstream, worst-case output remains brick-walled. No new limiter logic needed.
- **Dose:** the post-EQ spectrum tap feeds the dose tracker downstream of dynamics, so added boost is automatically counted. No tracker changes; verify in tests that an engaged Speech Presence raises measured level as expected.
- **Framing:** panel footer carries one sentence: "These tools shape audio for comfort and clarity. SherlockEQ is not a hearing aid or a medical device." (Localize; reuse phrasing in onboarding later.)

---

## 8. Files Touched (expected)

| File | Change |
|---|---|
| `Audio/DynamicBandProcessor.swift` | NEW — detector + envelope + gain computer + modulated biquad, per §3 |
| `Models/DynamicFeature.swift` | NEW — kinds, settings structs, DSP constants, strength/sensitivity mappings |
| `Models/HearingProfile.swift` | `dynamics` field + `decodeIfPresent` |
| `Audio/CATapEngine.swift` | own 2 processors; render-block calls; SR plumb |
| `Audio/SherlockEQAudioEngine.swift` | attach params, applyProfile fold, flatten/teardown/reference-mode coverage |
| `State/EQChainState.swift` | `dynamicsBypassed` stage toggle |
| `State/AudioState.swift` | expose activity telemetry object; wire bypass sink |
| `UI/Window/Clarity/ClarityView.swift` | NEW — panel per §6.1 |
| `UI/Window/Clarity/DynamicFeatureCard.swift` | NEW — card + activity meter |
| `UI/Window/MainWindowView.swift` + sidebar enum | new section + route |
| `UI/Components/CanvasLayerChipStrip.swift` | Dynamics chip |
| `UI/Components/ParametricCanvasView.swift` | dynamics overlay stroke |
| `UI/Window/Equalizer/ExpertEQView.swift` | pass overlay flag + live deltas |
| `SherlockEQTests/DynamicBandProcessorTests.swift` | NEW — §9.1 |
| `SherlockEQTests/HearingProfileDecoderTests.swift` | backward-compat cases |

---

## 9. Testing Plan

### 9.1 Unit tests (`DynamicBandProcessorTests`, Swift Testing)

1. **Passthrough equivalence** — all slots disabled, or enabled with strength 0: output bit-identical to input.
2. **Bypass equivalence** — `setBypassed(true)` with active slots: bit-identical passthrough; state cleanly reset on un-bypass.
3. **Attack/release ballistics** — feed a gated sine in the detector band; measure 10→90 % gain-engage and release times; assert within ±30 % of the feature's constants.
4. **Max-delta clamp** — pathological input (full-scale detector-band tone, strength 1.0) never exceeds the feature's max delta.
5. **Adaptive threshold** — same relative burst over a quiet bed and a loud bed produces equivalent engagement (level independence).
6. **Stability under modulation** — minutes of square-wave bursts straddling threshold at high strength: no NaN/Inf, bounded filter state, bounded output.
7. **Denormal handling** — long silence after signal: state flushes, no lingering subnormals.
8. **Speech Presence gating** — boost engages on detector-band content, returns to ≤ 0.1 dB within release time after content stops (never amplifies pauses).
9. **Coefficient correctness** — at a frozen gain delta, processor output matches a static `BiquadCascade` configured with the same bell (within float tolerance) — ties dynamic processing to the shared cookbook.
10. **Decoder backward compat** — pre-dynamics profile JSON decodes with all-disabled defaults; round-trip preserves settings.

### 9.2 Performance checks

- Render-block budget: measure worst-case per-buffer time with 3+3 triggered slots on top of a realistic cascade; assert comfortable margin against the buffer deadline at 48 kHz.
- Idle cost: untriggered slots ≈ sidechain-only cost; all-disabled ≈ zero.
- UI: Clarity panel + Dynamics overlay visible must not regress the post-audit idle CPU numbers; meters fully gate off when not visible.

### 9.3 Listening test checklist (manual, gates release)

- Sibilance: harsh-"s" podcast material — cut engages on esses only, no dulling between them, no zipper on sustained tones.
- Harshness: loud compressed pop/rock — tamed without sounding filtered.
- Speech Presence: movie dialogue over score — dialogue lifts, music interludes don't pump, pauses stay silent.
- Each feature at strength 0 → audibly transparent; Reference Mode kills everything instantly.
- L/R separate mode: feature on one ear only behaves independently (verify with the existing channel-separation measurement workflow — this feature must not reintroduce a cross-channel leak).

---

## 10. Deferred: Expert-mode dynamic band editing

Out of scope. Revisit only when both are true: (a) users ask for custom dynamic bands beyond the three presets, and (b) there's appetite for the canvas redesign. The known costs, recorded so future-us doesn't rediscover them:

- Node semantics: node = static/max gain, animated fill = live gain (FabFilter-style); requires rework of node drawing, hit-testing, and drag in `ParametricCanvasView`.
- The cached-EQ-curve optimization must learn to composite a static cached layer with an animated dynamic layer.
- Controls bar: a "Dynamic" disclosure adding a second row (threshold/ratio/attack/release); keyboard map extension.
- Storage: per-band dynamics would finally have to live in `EQBand` — re-opening the `ownedSlots` / `audiblyEquivalent` / preset / AutoEQ-combine questions deliberately avoided in this spec (Design Note 1).

## 11. Deferred: WDRC (loudness-dependent correction)

Separate future spec. Key shape, recorded for continuity: audiogram-derived per-band compression curves (NAL/DSL-style prescription, simplified + conservative), likely a Linkwitz-Riley filterbank per ear rather than modulated bells, and — critically — it converts `calibrationOffsetDBA` from documentation-only into an audio-affecting parameter, which raises the calibration workflow's accuracy bar and demands explicit max-boost safety rules and product framing review before any engineering starts.

---

## 12. Implementation Order & Effort

Suggested commit sequence (each independently buildable):

1. Models: `DynamicFeature.swift` + `HearingProfile.dynamics` + decoder tests.
2. `DynamicBandProcessor` + full §9.1 test suite (no engine wiring yet — pure DSP, test-first).
3. Engine wiring: CATapEngine ownership + render-block calls + applyProfile fold + reference/flatten/teardown coverage + `EQChainState.dynamicsBypassed`.
4. Telemetry: gain counters + refcounted sampling object.
5. Clarity panel UI (cards, separate-L/R, a11y, localization).
6. Expert canvas Dynamics chip + overlay.
7. Listening-test tuning pass on the §2 constants; perf verification.

**Effort estimate:** steps 1–2 ≈ one session (the DSP core is the bulk); steps 3–4 ≈ half a session; steps 5–6 ≈ one session; step 7 is open-ended by nature — budget real listening time across days of normal use before calling the defaults final. Total ≈ 2.5–3 sessions plus tuning.

## 13. Open Questions

1. Panel name: "Clarity" is the working title — alternatives: "Dynamic Processing" (precise, engineer-flavored), "Listening Comfort". Decide before the sidebar string lands in the catalog.
2. Should Speech Presence's detector band and bell be user-shiftable (a third "voice pitch" slider) for non-typical voices, or is fixed-band good enough for v1? Lean: fixed for v1.
3. Does the popover eventually get a single "Clarity on/off" master toggle next to the notch toggle? Lean: yes, but only after v1 proves the features earn daily-driver status.
4. Activity history: is the instantaneous meter enough, or do users want a "this feature acted N times today" stat (à la dose tracking)? Defer until real usage shows demand.
