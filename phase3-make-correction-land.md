# SherlockEQ — Phase 3: Make the Correction Land

**Feature set:** Seven changes that remove the reasons the NAL-R correction core fails to reach the user's ears
**For:** Claude Code implementation sessions (one item ≈ one PR; see §9)
**Scope:** EQ surface consolidation (Graphic + Parametric) · 12-band audiometric grid · outcome presets + factory re-voicing + genre quarantine · in-app Listening Check · compensation default + acclimatization ramp · notch/correction conflict detection · AutoEQ device-mismatch detection
**Status:** 📋 Specified — not yet implemented
**Spec date:** 2026-07-14 (rev 2 — adds §1 surface consolidation per product decision, replaces the four-mode model)

---

## 0. The through-line

Phases 1–2 fixed the safety math and cut the surface that served nobody. Phase 3
is about one thing: **the app's scientifically-solid correction engine (NAL-R,
per-ear cascades) rarely reaches users' ears at effective strength.** Each item
below removes one specific obstruction:

| § | Obstruction | Fix |
|---|---|---|
| 1 | Four EQ "modes" that are really overlapping lenses on one band array — users pick a skill level, not a tool, and can hear processing they can't see | Two surfaces: **Graphic EQ** + **Parametric EQ** |
| 2 | Advanced EQ has no sliders at 3 & 6 kHz — audiogram frequencies where presbycusis lives | 12-band audiometric grid |
| 3 | The default preset is perceptually a no-op; presets are named after genres and skill, not outcomes; "Loudness compensation" is wrong physics | Outcome presets, factory re-voicing, genre quarantine |
| 4 | NAL-R is gated on owning a clinical audiogram, which ~no target user has | In-app Listening Check |
| 5 | Default strength halves an already-conservative prescription | Full-strength target + acclimatization ramp |
| 6 | The tinnitus notch silently fights the correction at exactly the frequencies that matter | Conflict detection |
| 7 | A headphone correction stays active (−6 dB preamp and all) on the wrong output device | Mismatch detection |

## Design notes (read before implementing)

**1. Drawn = heard, always.** Several items introduce gain that varies over time
(§5 ramp) or state that changes what's applied (§7 bypass). Every such factor
must live in ONE pure helper consumed by both the audio engine and the drawing
code (`EQPreviewView`, canvas Result/Correction curves) — the `BiquadCoefficients`
precedent. A preview that disagrees with audio is worse than no preview.

**2. Nothing active may be invisible.** The consolidation's hard invariant
(product decision, 2026-07-14): Graphic EQ must show the **entire active
result**, even when some filters can't be represented by its sliders. Old
Simple/Speech filters never silently keep running as hidden manual EQ — they
either get converted onto the graphic bands or appear as an explicit,
labeled legacy layer with a visible "Convert" action (§1.4). This generalizes
the old `HiddenBandsHintChip` mitigation from a warning into a guarantee.

**3. Never clobber a user edit.** §3 changes factory preset values, and factory
presets are editable in place (`isBuiltIn` is not a lock). The migration must
distinguish "still exactly the v1 factory values" (safe to upgrade) from
"user-edited" (leave alone). This requires freezing the v1 definitions in the
migration code — comparison against the *current* builders is circular.

**4. The Listening Check is an estimate, and says so.** We control dBFS, not
dB HL. The dBFS→dB HL mapping runs through the user's SPL calibration (Phase 1
made it volume-anchored, which is what makes this feasible at all) plus a
generic transducer constant, so the absolute anchor carries ±5–10 dB of
uncertainty. That is acceptable: NAL-R's prescription is dominated by audiogram
*shape*, and a 10 dB anchor error moves overall gain by only ~4.6 dB
(0.31·10 + 0.05·30), which the strength slider and ramp absorb. Every screen
of the flow uses "listening check" / "estimate" framing — never "hearing test",
never a clinical claim. Same discipline app-wide: no preset or copy may imply
hearing-aid equivalence (the "Hearing-aid lite" preset name is removed — OTC
hearing aids are regulated devices with defined validation expectations).

**5. No silent audio changes.** §7 could auto-bypass a mismatched correction;
§5 could snap strength on a timer; §1's migration could quietly rewrite bands.
All forbidden. The ramp moves at most once per calendar day and is labeled;
the mismatch warning offers a one-click bypass but never acts alone; band
conversion happens only on the user's explicit action (and is undoable).

**6. Item order matters.** §2 (grid) defines the canvas §1's Graphic surface
and §3's preset curves live on — build §2 → §1 → §3 in that order. §4's Apply
step starts §5's ramp — build §5 before §4.

---

## 1. EQ surfaces: collapse to Graphic EQ + Parametric EQ

### 1.1 The problem

The four modes (Simple / Speech / Advanced / Expert) *appear* to be increasing
capability levels but are actually different lenses editing overlapping slices
of one band array (`EQMode.ownedSlots`). Three consequences:

- Simple, Speech, and Advanced aren't clean levels of one control system —
  they use different frequencies and filter types, so "upgrading" isn't
  monotone.
- A user can hear processing they cannot see or edit on their chosen surface
  (the hidden-bands chip is a mitigation whose *existence* is the evidence the
  model fights the user's mental model).
- "Speech" reads as an evidence-backed intervention; it is six fixed EQ
  choices. Individual speech benefit depends on thresholds, level, device,
  content, and environment — a fixed curve can't claim that mantle.

An entire subsystem (`ownedSlots`, `HiddenBandsHintChip` accounting,
non-destructive mode-switch semantics, four view files) exists solely to manage
leakage between the four lenses. Two honest surfaces delete most of it.

### 1.2 Target architecture

| Surface | Was | What it is |
|---|---|---|
| **Graphic EQ** *(default)* | Advanced | 12-band audiometric graphic EQ (§2). Hierarchy top→bottom: prominent **purpose/preset selector** (§3.2) → response curve → 12 sliders → footer route to Parametric. Optional label toggle: frequency labels ("3k") ↔ friendly region labels (Speech's vocabulary: "Vocal warmth", "Consonant clarity", "Sibilance", …). |
| **Parametric EQ** | Expert | Unchanged capabilities: arbitrary freq/gain/Q/type, draggable nodes, per-ear editing, spectrum + overlays, keyboard map. A materially different *editing model*, not "more sliders" — that's what justifies a second surface. |

Names describe tools, not people ("Expert" described a person). A profile
selects Graphic or Parametric — not a skill level.

**Simple and Speech are deleted as modes.** Their value survives as:
- Speech's perceptual vocabulary → Graphic's friendly region labels + help
  copy + the "Clearer voices" purpose preset (§3.2).
- Simple's approachability → the purpose-preset selector itself, plus the
  popover and Analog Control Unit for quick-tone jobs.
- Speech's use-case presets (Audiobook / TV dialogue / …) → absorbed by
  "Clearer voices"; the "Hearing-aid lite" name is retired outright (Design
  note 4).

### 1.3 Model & storage

- `EQMode`: UI exposes two cases. **Persisted raw values stay `"advanced"` /
  `"expert"`** (display names change; stored strings don't — keeps profile
  JSON import/export and old exports decodable). Decoder maps legacy
  `"simple"` and `"speech"` → `.advanced` (Graphic). New profiles default to
  Graphic.
- `ownedSlots`: Graphic owns the 12 parametric slots (§2); Parametric owns
  everything (nil). Simple/Speech slot sets deleted.
- View files `SimpleEQView.swift`, `SpeechEQView.swift` deleted;
  `EqualizerView` switches over two cases; Profile Detail's mode picker
  becomes a two-option control with one-line descriptions.

### 1.4 Migration — the "nothing invisible" invariant

For any profile whose band array contains bands outside Graphic's 12 slots
(migrated Simple/Speech profiles; Parametric-authored bands on a profile
switched to Graphic):

- The **response curve already shows them** (the preview draws the full band
  array — verified) — the curve is honest today; the sliders aren't the whole
  story. So:
- A labeled **"Other filters" layer row** appears between curve and sliders:
  *"N filters from an older mode / Parametric are active but not on these
  sliders."* Two actions:
  - **Convert to Graphic EQ** — sample the non-graphic bands' composite
    response at the 12 centers and fold it into the slider gains via the same
    damped fixed-point fit `AudiogramConversion` already uses for overlapping
    bells (so the realised curve matches the target, not a naive per-point
    copy), then delete the originals. One undo step ("Convert filters"),
    existing `ProfileStore` undo machinery.
  - **Edit in Parametric** — the existing escape hatch.
- No auto-conversion at migration time (Design note 5). Decode-time mode
  mapping is the only silent change, and it changes *which editor opens*, not
  the audio.

### 1.5 Integration points that must keep working

- **Analog Control Unit** — its Bass/Mid/Treble knobs write Simple-slot bands
  on its own *hidden* override profile, which never renders in the Equalizer
  UI. Unaffected; the band slots remain valid `EQBand`s. Its header comment
  updates ("Simple-EQ tone" → "three-band tone").
- **CLI / Siri `simple-eq`** (`AppControlService`) — keeps working against the
  same three slots on the active profile. Consequence: using it on a Graphic
  profile creates off-grid bands → the "Other filters" row appears with the
  Convert action. Documented in the CLI help text. (Re-mapping the command
  onto graphic bands is an open question, §11.)
- **Factory presets** are Graphic-mode profiles (already `.advanced`) — no
  change beyond §3's re-voicing.
- **Help docs**: `simple-eq.md`, `speech-eq.md`, `advanced-eq.md`,
  `parametric-eq.md`, `understanding-eq.md`, `feature-guide.md` — consolidate
  to `graphic-eq.md` + `parametric-eq.md` with redirect stubs (bare-slug
  loading means old `help:` links must keep resolving; keep the old slugs as
  thin "this moved" pages or alias them).

### 1.6 Evidence basis (recorded so future-us doesn't re-litigate)

Two-surface + small-preset-set direction is supported: a population-based
four-preset system covered ~68 % of its target sample with intelligibility
comparable to individual prescription (PMC11001427); month-long self-fitting
succeeded with a simple constrained-exploration interface (Sabin et al.,
PMC7099667); paired comparison beats categorical rating for finding preferred
responses (PMC4111476). What's *not* supported: one fixed "speech" curve for
everyone, audiogram-as-inverse-EQ, or hearing-aid equivalence claims (FDA OTC
guidance; ASHA fitting guidance). The NAL-R starting shape + strength control
remains the defensible core.

### 1.7 Files

DELETE `UI/Window/Equalizer/{SimpleEQView,SpeechEQView}.swift`;
`Models/HearingProfile.swift` (EQMode cases/decode/ownedSlots),
`UI/Window/Equalizer/EqualizerView.swift` (two-case switch, "Other filters"
row lives in the Graphic view), `AdvancedEQView.swift` → renamed surface
(file rename optional; display name mandatory), `ProfileDetailView` (picker),
`Intents/AppControlService.swift` (help copy), Documentation consolidation,
`HearingProfileDecoderTests` (legacy-mode mapping), new conversion-fit tests.

---

## 2. Graphic EQ: 12-band audiometric grid

### 2.1 The problem

The `31.5 … 16k` octave set is a hi-fi convention. **3 kHz and 6 kHz —
audiogram frequencies, where presbycusis bites and consonant energy lives —
have no slider**, so the EQ surface and the audiogram screen don't speak the
same language at exactly the frequencies that matter most.

### 2.2 Change

- Centers → `[31.5, 63, 125, 250, 500, 1000, 2000, 3000, 4000, 6000, 8000,
  16000]` (12 bands; 31.5/16k retained — decorative for this audience but
  harmless, and removal would orphan existing band data).
- `ownedSlots` for Graphic gains the two parametric slots. Side effect
  (desirable): Parametric-authored 3k/6k bands become editable in Graphic
  instead of landing in the "Other filters" row.
- Label formatting "3k"/"6k"; 12 sliders fit the 760 pt minimum detail column
  (verify at Dynamic Type XL; existing overflow behavior covers the rest).
- **No storage migration** — bands are stored by (frequency, type); existing
  profiles simply gain two empty slots.

### 2.3 Files

`AdvancedEQView.swift` (frequencies + layout), `Models/HearingProfile.swift`
(`ownedSlots`, `advancedBands`), `EQBandLookupTests` fixtures.

---

## 3. Presets: outcomes, not genres or skill

### 3.1 The problems (2026-07-14 audit)

- **Music Balanced** — the cold-start default — is `[0.5, 1, 0.5, −0.5, 0, 0,
  0.5, 1, 0, −0.5]`: max ±1 dB on octave bands, below JND on program material.
  A first-run Reference-Mode A/B compares silence to silence.
- **Presence Boost** is Voice Clarity at ~60 % scale — a redundant slot.
- **"Loudness compensation"** (Advanced *and* Simple menus) applies a *static*
  bass shelf impersonating an equal-loudness contour — wrong physics by
  definition (equal-loudness is level-dependent). Deleted. (A correct,
  SPL-keyed version becomes possible post-Phase-1; separate future spec.)
- Fifteen genre presets in one flat menu, presented as peers of the
  correction, competing with it for headroom.

### 3.2 One shared curve table: the purpose presets

A single `PresetCurve` table (12-band gains + trim + description) is the
source of truth for BOTH the Graphic EQ header selector and the factory
profiles — one place to tune, impossible to drift apart:

| Purpose preset | Gains (dB, 12 bands: 31.5/63/125/250/500/1k/2k/3k/4k/6k/8k/16k) | Trim | Notes |
|---|---|---|---|
| Flat | all 0 | 0 | reset |
| Clearer voices | −4, −3, −2, −1, 0, +1, +2, +2.5, +3, +2, +1, −1 | −2 | absorbs Speech's job; was Voice Clarity's intent, strengthened at 3k/6k |
| Music balance | +1.5, +2, +1, −0.5, −0.5, 0, +1, +1.5, +1.5, +1, +0.5, 0 | −1 | the audible default: warmth + mud dip + gentle clarity |
| Gentle listening | 0, 0, +0.5, +0.5, 0, 0, −0.5, −1, −2, −3, −3.5, −4.5 | 0 | fatigue/harshness relief, deeper taper than v1 |
| Reduce boom | −3, −2.5, −2, −1.5, −0.5, 0, +0.5, +0.5, 0, 0, 0, 0 | 0 | bass-masking relief (boomy rooms/headphones/laptop DSP) |
| Reduce harshness | 0, 0, 0, 0, 0, −0.5, −1.5, −2.5, −2.5, −1.5, −1, −0.5 | 0 | 2–5 kHz shout/compression-artifact region; hyperacusis-friendly |
| Custom | — | — | sentinel; selector shows it whenever sliders diverge from every preset |

Graphic EQ's selector presents exactly these seven (small,
evidence-derived, outcome-named — see §1.6). Selecting one writes the
graphic slider gains (undoable, standard save path).

**Genre presets** (Warm, Bright, V-shape, Classical, …, Techno) move to a
secondary **"Tone flavors"** submenu with a `.callout/.secondary` header:
*"Taste presets — not hearing correction. They stack with your profile's
correction."* `loudness` is deleted from both former menus. Simple's preset
enum dies with its view (§1).

### 3.3 Factory profiles (v2)

Still four onboarding cards, now wrapping shared curves:

| Factory profile | Curve | Notes |
|---|---|---|
| Voice Clarity | Clearer voices | name kept — established identity |
| Music Balanced *(default)* | Music balance | now audible on A/B |
| Gentle Listening | Gentle listening | |
| **Reduce Boom** | Reduce boom | **replaces Presence Boost** (redundant with Voice Clarity); new stable UUID; reconcile retires the old id |

`presetDescription`/`presetTags` updated to outcome language ("Voices are
hard to follow" / "Audio sounds boomy or muddy" …) — the onboarding cards
become the lean version of the outcome-based entry point ("What would you
like to improve?"). The full guided A/B-listening flow with representative
content is deliberately deferred (§8).

### 3.4 Migration (Design note 3)

- Bump `factoryPresetsVersion` 1 → 2.
- `reconcileFactoryPresets()` upgrade step for canonical presets present by
  id: compare against a **frozen v1 table** (the four v1 gain arrays + trims,
  private to ProfileStore) via `audiblyEquivalent` + trim equality.
  Unedited → replace with v2. Edited → leave entirely alone.
- Presence Boost: id leaves the canonical set → reconcile's existing
  legacy-removal deletes it **only if unedited**; an edited Presence Boost is
  preserved as a user-owned profile (`isBuiltIn` flipped false, star removed)
  rather than deleted — never destroy user work.
- Active-profile repoint via existing `adoptDefaultProfileIfNeeded`.

### 3.5 Files

`Models/HearingProfile.swift` (curve table, factory builders),
`Persistence/ProfileStore.swift` (version bump, frozen v1 table, upgrade +
Presence-Boost demotion), Graphic view (selector), onboarding copy,
`ProfileStoreTests`.

---

## 4. Listening Check (in-app hearing estimate)

### 4.1 What it is

A guided, per-ear threshold estimate at the 8 audiogram frequencies, using the
**modified Hughson–Westlake** ascending method — the same procedure an
audiologist uses, minus the calibrated booth. Output feeds the existing
audiogram → NAL-R path unchanged. This unlocks the app's core feature for the
~95 % of users who will never type in a clinical audiogram.

**Name:** "Listening Check" everywhere. Never "hearing test." Results carry
the existing non-clinical caveat plus: *"This is an estimate made with your
own headphones in your own room. It cannot diagnose anything. For persistent
hearing concerns, see a hearing-care professional."*

### 4.2 Signal path & tone generation

- Reuse `SineToneGenerator` (continuous-phase, attached to `mainMixerNode`,
  bypasses EQ — exactly right: the check must measure the ear, not the
  correction). Two extensions:
  - **Channel mask** — present to left or right ear only (`makeSourceNode`
    currently copies channel 0 to all channels; add a per-channel gain mask).
  - **Pulse envelope** — clinical presentation is pulsed: 3 × 200 ms on /
    200 ms off per trial, with **5 ms raised-cosine ramps** on every edge (a
    hard-keyed sine clicks, and clicks are audible below the tone's own
    threshold — invalidates the measurement).
- Levels on an internal dBFS grid, 5 dB steps.
- **Safety ceiling (do-no-harm):** presentation never exceeds
  `min(−25 dBFS, (80 dBA − effectiveCalibrationOffsetDBA))`. With default
  calibration 100 → ceiling −25 dBFS ≈ 75 dB SPL. The Phase-1 volume anchor
  is load-bearing here — see §4.4.

### 4.3 Procedure (state machine, unit-testable)

Per ear (user picks "which ear seems better?" to test first; skippable →
left):

1. **Familiarization** at a comfortably-audible level (estimated 40 dB HL
   equivalent) at 1 kHz — "press when you hear the pulses."
2. **Staircase per frequency:** down 10 dB after each response, up 5 dB after
   each miss. **Threshold = lowest level responded to in ≥ 2 of up to 3
   ascending presentations.**
3. **Frequency order:** 1k → 2k → 3k → 4k → 6k → 8k → 500 → 250 → **1k
   retest**. Retest differing > 10 dB from the first 1k flags the ear's run
   low-reliability (banner on results; offer redo — never silently average).
4. **Catch trials:** ~15 % silent presentations. > 2 false alarms per ear →
   reliability warning.
5. **Response window:** 1.5 s from pulse-train onset; button + spacebar.
6. **No response at ceiling** → frequency records as *unmeasurable* (no
   threshold stored, excluded from NAL-R derivation); results screen shows the
   existing ">40 dB loss" professional-help caveat. We never chase a
   threshold above the safety ceiling.

**Volume integrity:** at flow start, snapshot `systemVolume.volumeDB` (Phase 1
plumbing). Any volume/mute/device change mid-run **pauses the check** with a
banner ("System volume changed — set it back to continue, or restart").
Completed frequencies are kept; the interrupted trial repeats.

**Environment gates (preconditions screen):**
- Output device transport == built-in speakers → **block** with explanation
  (headphones required; crosstalk + room noise make speaker thresholds
  meaningless). New `CATapEngine` nonisolated helper reads
  `kAudioDevicePropertyTransportType`.
- Quiet-room instruction (the app deliberately has no microphone access —
  instruct, don't verify).
- Calibration status shown: `volumeTrackingStatus == .active` → "anchored";
  otherwise → "estimate will be less accurate — calibrate in Safe Listening
  for better results" (not blocking).

### 4.4 dBFS → dB HL mapping

`estimatedDBHL(f) = (dBFS + effectiveCalibrationOffsetDBA) − RETSPL(f)`

- `RETSPL(f)`: one fixed generic supra-aural table (ANSI S3.6-derived
  constants) in the state-machine file. Named constants, one place.
- Absolute anchor error ±5–10 dB is expected and disclosed (Design note 4).
  Shape — the thing NAL-R chiefly consumes — survives because all frequencies
  share the anchor.

### 4.5 Results & apply

- Results overlay on the existing `AudiogramChartView` (VO/keyboard a11y for
  free), reliability flags, caveat copy.
- **Apply** writes `AudiogramPoint`s into `leftEar/rightEar.thresholds`,
  re-derives `correctionBands` (the exact path manual entry uses), then
  starts the §5 acclimatization ramp.
- New profile fields `audiogramSource: AudiogramSource` (`.manual` /
  `.listeningCheck` / `.imported`; `decodeIfPresent`, default `.manual`) +
  `audiogramDate: Date?` — the Audiogram screen shows "From Listening Check,
  Jul 14 2026".

### 4.6 Files

NEW `Models/ListeningCheckSession.swift` (pure state machine — staircase,
threshold rule, catch trials, retest validity; fully unit-tested, no audio),
NEW `UI/Window/Audiogram/ListeningCheckView.swift`,
`Audio/SineToneGenerator.swift` (mask + envelope), `Audio/CATapEngine.swift`
(transport helper), `Models/HearingProfile.swift` (source/date fields),
`UI/Window/Audiogram/AudiogramView.swift` (entry + provenance),
`SherlockEQTests/ListeningCheckSessionTests.swift`.

---

## 5. Compensation default + acclimatization ramp

### 5.1 The problem

NAL-R already prescribes ~⅓ of the loss (0.31·HTL) because full restoration is
intolerable; `compensationFactor` scales that again, defaulting to **0.5** —
net ~0.155·HTL. A 40 dB loss at 4 kHz gets ~6 dB where the prescription says
~12. The 0.5 default is a workaround for the absence of an adaptation path —
so build the adaptation path.

### 5.2 Mechanics

- When an audiogram is applied (Listening Check Apply, manual entry, import),
  set `compensationFactor = 1.0` (full prescription as *target*) and stamp
  `acclimatizationStartDate = now`.
- **Effective strength** = `compensationFactor × ramp(t)`, ramp rising
  linearly **0.6 → 1.0 over 21 days**, clamped at 1.0. Nil stamp → factor 1.0
  (legacy behavior).
- Pure helper `AcclimatizationRamp` + `HearingProfile.effectiveCorrectionBands(now:)`
  — single source of truth for engine (`applyProfile`), `EQPreviewView`, and
  canvas Result/Correction curves (Design note 1). Stored `correctionBands`
  remain the full-strength prescription.
- **Daily refresh:** `AudioState` re-runs `applyActiveProfile()` on
  `NSCalendar.dayChangedNotification`. One step/day ≤ ~0.7 dB per band —
  inaudible as a transition; cascade state-zeroing covers coefficient swaps.
- **Migration:** existing profiles keep their `compensationFactor`, get no
  stamp — nothing changes until the next audiogram application. Slider
  (popover + Profile Detail) keeps its role as the target; range stays
  0.25–1.0.

### 5.3 UI

- Audiogram screen chip while ramping: *"Acclimatization: day N of 21 —
  correction at X %."* + **"Skip to full strength"** (clears the stamp).
- Profile Detail Tuning row with the same state.
- `.callout` copy explaining why the ramp exists (mirrors real-world fitting
  practice; non-clinical wording).

### 5.4 Files

NEW `Audio/AcclimatizationRamp.swift`, `Models/HearingProfile.swift`,
`Audio/SherlockEQAudioEngine.swift`, `State/AudioState.swift` (day observer),
Audiogram + ProfileDetail chips, `AcclimatizationRampTests`.

---

## 6. Notch / correction conflict detection

### 6.1 The problem

Presbycusic tinnitus overwhelmingly sits in the region of maximum loss, so the
notch center typically lands exactly where NAL-R prescribes its largest boost.
A −15 dB, Q 2 notch against a +12 dB correction at the same frequency is one
filter bank arguing with itself — and today nothing says so.

### 6.2 Mechanics

- Pure helper (NEW `Audio/CorrectionConflict.swift`): for an enabled notch and
  the ear's correction bands, evaluate the correction's composite magnitude at
  the notch frequency via `BiquadResponse.compositeMagnitudeDB`. **Conflict**
  when correction ≥ +4 dB there and notch depth ≤ −6 dB. Returns both
  magnitudes for the copy. Per-ear.
- Surfaces (persistent inline chip, `HiddenBandsHintChip` pattern — NOT
  NoticeCenter; durable state, not a transient event): Tinnitus Notch screen
  (per affected ear panel) + Audiogram screen (below chart).
- Copy: *"Your hearing correction boosts +X dB at N Hz — right where your
  notch cuts Y dB. They partially cancel. A narrower notch width keeps more
  of the correction; a shallower notch keeps more relief."* Both controls one
  click away from each surface.
- **No auto-fix in v1.** The tradeoff is genuinely the user's to make.

### 6.3 Files

NEW `Audio/CorrectionConflict.swift`, chips in `ToneFinderView` +
`AudiogramView`, `CorrectionConflictTests`.

---

## 7. AutoEQ correction ↔ output-device mismatch

### 7.1 The problem (found empirically, 2026-07-14)

A DT770 Pro X correction (−6 dB preamp + 10 bands) stayed active while output
was MacBook Air Speakers. The user experienced it as "output levels dropped"
— meters ~6 dB lower, audio quieter — and nothing connected the dots. The app
*knows* the correction targets a specific headphone and *knows* the current
output device; it just never compares them.

### 7.2 Mechanics

- New profile fields (`decodeIfPresent`): `autoEQDeviceUID: String?` +
  `autoEQDeviceName: String?` — recorded at attach time (ProfileDetail file
  picker, library menu, `AutoEQSearchView` import) from the then-current
  default output device. Legacy corrections (nil UID) produce **no warning**
  until re-attached — no fuzzy model-name matching, no guessing.
- Detection in `AudioState` (recompute on active-profile change and
  `onOutputDeviceChanged`): active profile has AutoEQ bands + `autoEQEnabled`
  + recorded UID ≠ current device UID → publish `autoEQMismatch:
  AutoEQMismatch?` (correction name, attached device name, current device
  name). `SystemVolumeController.deviceUID` (Phase 1) already publishes the
  current UID — reuse.
- Surfaces:
  - **Popover** row under the compensation slider: *"'DT770 Pro X' correction
    was set up for [attached device] — you're on [current device]."* Buttons:
    **Bypass here** (`eqChain.autoEQEnabled = false`, session-scoped, existing
    toggle) · **Dismiss**.
  - **Graphic/Parametric screens:** same message as an inline chip.
  - Dismissal remembered per `(profileID, deviceUID)` in UserDefaults — warn
    once per new combination, never nag.
- Extra copy weight when current transport is built-in speakers (a headphone
  curve on speakers is always wrong, not just probably).
- **No auto-bypass in v1** (Design note 5) — open question.

### 7.3 Files

`Models/HearingProfile.swift`, `ProfileDetailView` + `AutoEQSearchView`
(record at attach), `State/AudioState.swift`, popover + equalizer surfaces,
`HearingProfileDecoderTests`.

---

## 8. Explicitly out of scope for Phase 3

- **WDRC** (Phase 4 — §5's ramp and §4's audiogram supply are prerequisites,
  not substitutes).
- Level-dependent loudness compensation (the correct replacement for the
  deleted static preset; own spec, post-Phase-1 SPL trust).
- **Guided A/B preset selection with representative content** (the full
  "hear alternatives and pick" flow — paired comparison beats rating scales
  per the evidence, but it needs bundled/licensed program material and
  playback machinery; the outcome-named presets + onboarding cards are the
  lean v1). Backlog, high interest.
- Speech-in-noise enhancement; outcome validation (on/off forced-choice
  speech check); latency measurement.

## 9. Implementation order & effort

Each step independently shippable (own branch + PR, per house workflow):

1. **§2 12-band grid** — foundation. ≈ half a session.
2. **§1 surface consolidation** — before preset work so it lands once, on the
   surviving surfaces. ≈ 1.5–2 sessions (deletions are easy; the conversion
   fit + migration tests are the bulk).
3. **§3 presets** — depends on §1 + §2. ≈ 1 session.
4. **§7 device mismatch** — independent, small. ≈ half a session.
5. **§6 conflict detection** — independent, small. ≈ half a session.
6. **§5 ramp** — before the check so Apply can start it. ≈ 1 session.
7. **§4 Listening Check** — the big one. ≈ 2–3 sessions (state machine +
   tests first, then tone-generator extensions, then flow UI).

Total ≈ 7–8.5 sessions.

## 10. Testing plan

- **§1:** decoder maps simple/speech → graphic; export/import round-trips;
  conversion fit — converted 12-band curve matches the source composite
  within tolerance across 20 Hz–20 kHz; convert is one undo step; CLI
  `simple-eq` still round-trips; "Other filters" row appears/disappears
  correctly.
- **§2:** `EQBandLookup` fixtures at 3k/6k; a Parametric-authored 3k band is
  editable in Graphic.
- **§3:** ProfileStoreTests — v1-unedited upgrades to v2; v1-edited untouched;
  edited Presence Boost demotes to user profile (not deleted); unedited
  Presence Boost removed + Reduce Boom installed; deleted preset stays
  deleted; restore forces v2; fresh install gets v2; selector shows Custom on
  divergence.
- **§4:** ListeningCheckSessionTests — staircase transitions, 2-of-3 rule,
  catch bookkeeping, retest validity, ceiling → unmeasurable, volume-change
  pause; envelope continuity (sample-level assert on ramp edges); dB HL
  mapping.
- **§5:** ramp factor at day 0 / mid / ≥ 21 / nil; engine and preview consume
  identical values (shared-helper equality test).
- **§6:** conflict truth table; per-ear independence; disabled notch → never.
- **§7:** decoder back-compat; detection truth table (nil / match / mismatch /
  disabled); dismissal persistence.
- Manual listening pass for §3 voicings (A/B each vs Flat on speech + music)
  and §4 end-to-end with real headphones — gates release.

## 11. Open questions

| # | Question | Lean |
|---|---|---|
| 1 | ~~Target surface set~~ | **Decided 2026-07-14: Graphic EQ + Parametric EQ** (per product review with evidence; §1) |
| 2 | Fourth factory card: Reduce Boom (this spec) vs Reduce Harshness vs keep re-voiced Presence Boost? | Reduce Boom — distinct real problem; harshness relief already lives in Gentle Listening |
| 3 | CLI/Siri `simple-eq`: keep writing legacy slots (+ convert affordance) vs re-map onto graphic 250/1k/5k-ish bands? | Keep legacy slots in v1; revisit if the "Other filters" row confuses CLI users |
| 4 | Listening Check on built-in speakers: hard block (this spec) vs warn-and-allow with a quality flag? | Hard block — a speaker "audiogram" feeding NAL-R is worse than none |
| 5 | Ramp duration fixed 21 days vs selectable 14/21/28? | Fixed; "Skip to full strength" covers the impatient |
| 6 | §7 auto-bypass on built-in speakers? | Deferred — violates no-silent-changes; revisit with usage data |
| 7 | `AdvancedEQView.swift` file rename to `GraphicEQView.swift` now or later? | Now, in the §1 PR — cheap while everything else in the file is moving |
