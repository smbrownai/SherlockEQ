# SherlockEQ — Phase 4: Adaptive Correction (WDRC)

**Feature:** Level-dependent hearing correction — per-band gains that follow the input level, prescribed from the audiogram
**For:** Claude Code implementation sessions (see §9 for the split)
**Scope:** New per-ear DSP stage (Linkwitz–Riley filterbank + per-band gain computers), prescription math anchored to NAL-R, engine integration, correction-mode selector + level-aware previews, safety analysis
**Status:** 📋 Specified — awaiting product review (this feature was explicitly flagged in the dynamic-EQ design record as requiring "explicit max-boost safety rules and product framing review before any engineering starts")
**Spec date:** 2026-07-15

---

## 0. Why this is Phase 4, and why now

Sensorineural hearing loss means **loudness recruitment**: thresholds are
elevated, but loudness at high levels is near normal — the residual dynamic
range is compressed. A linear prescription like NAL-R can only be right at
one input level: fit it for quiet speech and loud passages arrive
over-amplified and harsh; fit it for comfort and quiet speech stays
inaudible. This is *why* NAL-R is a linear prescription for linear aids, and
why the field moved to compressive prescriptions (NAL-NL2, DSL v5). The
consequence is visible in SherlockEQ today: users set the strength for quiet
dialogue, a loud passage arrives with the same boost, it's uncomfortable, so
they back the slider off — and dialogue is under-corrected again. The old
0.5 strength default and the Phase-3 acclimatization ramp are both
workarounds for the absence of compression.

**Every prerequisite this feature was blocked on now exists:**

| Prerequisite | Status |
|---|---|
| Trustworthy SPL calibration (WDRC's gain depends on estimated at-ear level) | ✅ Phase 1: volume-anchored `effectiveCalibrationOffsetDBA`, empirically verified pre-volume tap |
| Audiogram supply (most users had none) | ✅ Phase 3 §4: the Listening Check |
| A strength/adaptation model to slot into | ✅ Phase 3 §5: consumption-time strength × acclimatization ramp |
| Safety accounting of added boost | ✅ dose tracker sits post-EQ; AUPeakLimiter downstream |

## Design notes (read before implementing)

**1. Calibration becomes audio-affecting — this is the safety event of the
feature.** Until now `calibrationOffsetDBA` only moved *displays* and the
dose estimate. WDRC uses it to decide how much gain to apply. §7 analyzes
every failure mode; the two structural mitigations are a **hard absolute
gain cap** independent of all inputs, and **reduced adaptation depth when
the calibration was never actually performed** (§7.3). The framing does not
change: SherlockEQ remains an audio personalization tool, not a hearing aid
— but the copy review in §6 matters more than usual.

**2. Scalar band gains, not modulated bells.** The dynamic-EQ feature
modulates biquad coefficients on the audio thread — workable for three
isolated bells, but N overlapping bells under independent dynamic gains sum
uncontrollably (the same overlap problem `AudiogramConversion` solves
statically with a damped fit, now time-varying). The filterbank architecture
dissolves the problem: crossovers are **static** IIR filters computed once;
the per-band dynamic element is a **smoothed scalar multiply** — the
simplest, safest realtime operation there is. Per-band gain is exact, and
the idle state is bit-flat by construction (§8's first test).

**3. Anchored to NAL-R at moderate level.** At 65 dB SPL input (moderate
speech), each band's gain equals the profile's existing NAL-R prescription.
Quieter inputs get more gain, louder inputs less, along a per-band
compression slope derived from the loss. This makes WDRC a strict
generalization of the current correction: a profile switched to Adaptive
sounds *identical* to Steady at moderate levels (§8's anchor test), and the
whole Phase-3 strength/ramp machinery applies unchanged.

**4. Opt-in, reversible, and visible.** `Steady` (static NAL-R) remains the
default. The mode is a per-profile choice on the Audiogram screen with an
honest explanation. Every surface that draws the correction becomes
level-aware (§6): the preview shows the quiet/moderate/loud family of
curves, and the canvas shows the *live* per-band gains — proof-of-work, and
the "drawn = heard" invariant extended to a moving target.

**5. Same realtime discipline as everything else in the Audio module.**
Config snapshot under `OSAllocatedUnfairLock` once per buffer; all state
pre-allocated; gain updates at block rate with smoothing and a deadband;
denormal flush; state zeroing on SR change / enable / bypass; Reference
Mode bypasses the stage alongside the cascades. No allocation, no
unbounded locks, no blocking on the audio thread.

---

## 1. Prescription math

### 1.1 Per-band compression parameters (from the audiogram)

For each band b with interpolated hearing threshold `HTL(b)` (dB HL, from
the profile's stored thresholds at the band's center frequency, log-
interpolated between audiogram points):

| Parameter | Value | Rationale |
|---|---|---|
| `G65(b)` | NAL-R REIG at the band center (the existing `AudiogramConversion` math) | anchor: Adaptive == Steady at 65 dB SPL |
| `CR(b)` | `clamp(1 + HTL(b)/60, 1.0, 2.5)` | gentle, loss-proportional; 2.5:1 cap is conservative vs. NAL-NL2's typical range |
| `kneeLow` | 45 dB SPL (band level) | below this, gain holds constant — no compression of near-silence |
| `kneeHigh` | 90 dB SPL | above this, gain has fully tapered |
| `Lref` | 65 dB SPL | moderate-speech anchor |

### 1.2 The gain rule

For estimated band input level `L(b)` (dB SPL):

```
L_c        = clamp(L(b), kneeLow, kneeHigh)
G_raw(b)   = G65(b) + (Lref − L_c) · (1 − 1/CR(b))
G_capped   = min(G_raw, G65(b) + maxExtraDB, absoluteCapDB)
G_final(b) = max(0, G_capped) · effectiveCorrectionStrength
```

- **Below `kneeLow`:** constant gain (`L_c` clamps) — ambient hiss is not
  chased upward. (True low-level *expansion* is a v2 tuning option, §10.)
- **Above `Lref`:** gain tapers below the NAL-R value, reaching its minimum
  at `kneeHigh` — loud passages get *less* boost than today's static
  correction, which is the comfort win.
- **`maxExtraDB = 10`:** adaptation may exceed the NAL-R anchor by at most
  10 dB (the intrinsic maximum at `kneeLow` with CR 2.5 is
  20 × 0.6 = 12 dB; the cap trims the extreme).
- **`absoluteCapDB = 24`:** hard ceiling on any band's insertion gain,
  independent of audiogram, calibration, and strength — the last line of
  defense (§7).
- **`max(0, …)`:** the correction layer never *cuts* below unity (NAL-R's
  negative k(250) values are already inside `G65`; the dynamic element only
  moves within [0, cap]). Tone shaping downward is the user EQ's job.
- **`effectiveCorrectionStrength`:** the Phase-3 target × acclimatization
  ramp, applied to the whole level-dependent gain — Adaptive ramps in
  exactly like Steady does.

All constants live in one type (`AdaptiveCorrectionPrescription`), the
`DynamicFeatureKind` convention: tuning is a one-file change.

### 1.3 Level estimation

`L(b) = bandDBFS(b) + effectiveCalibrationOffsetDBA`

where `bandDBFS` is the band's envelope-follower output (§3). This is the
Phase-1 volume-anchored offset — turning the volume down genuinely lowers
the estimated at-ear level, so WDRC adds gain for quiet listening: correct
behavior that static correction can't express.

## 2. Filterbank

Six bands per ear, Linkwitz–Riley 4th-order (LR4) crossovers at
**355 / 710 / 1400 / 2800 / 5600 Hz** — geometric band centers ≈ 250 / 500 /
1k / 2k / 4k / 8k Hz, i.e. the audiogram grid minus the 3/6 kHz half-octave
points (whose HTLs fold in via interpolation; six bands is the
resolution/CPU sweet spot for a first release — §10).

- Tree-structured complementary splits with all-pass compensation on the
  opposite branch of each crossover, so the **unity-gain sum is flat**
  (≤ 0.5 dB ripple 20 Hz – 20 kHz — asserted by test, not assumed).
- IIR throughout: **zero added latency** (LR phase rotation is inherent and
  standard practice; no lookahead, no FFT blocks).
- Crossover coefficients computed once per sample-rate change on the main
  thread; the audio thread only runs fixed biquads plus six smoothed scalar
  multiplies per ear.
- CPU: ~10 biquads (tree) + envelope math per ear — comparable to the
  existing per-ear cascade at typical band counts. No preemptive
  vectorization (the `DynamicBandProcessor` rule).

## 3. Detector, gain smoothing, realtime rules

- **Per-band envelope:** RMS detector in dB with attack/release ballistics —
  attack 5 ms / release 80 ms for bands ≥ 710 Hz; 10 ms / 150 ms for the two
  low bands (pumping on bass transients is the classic WDRC artifact).
- **Gain computer** (§1.2) evaluated at block rate (`updateInterval = 64`
  samples), applied through a one-pole smoother (τ ≈ 8 ms) with a 0.1 dB
  deadband — the `DynamicBandProcessor` recipe, minus the coefficient
  recompute (scalars only).
- **State resets** (all envelopes, smoothers, filter state) on: sample-rate
  change, mode enable, bypass off→on. Denormal flush per buffer at the
  established `1e-25` threshold.
- **Telemetry:** 6 bands × 2 ears `AudioCounter`s (milli-dB), sampled by a
  refcounted display-rate monitor — the `DynamicActivityMonitor` pattern —
  feeding the §6 live overlay. Nothing publishes through
  `AudioState.objectWillChange`.

## 4. Engine integration

### 4.1 Placement — order finally matters

The static chain is one commutative IIR cascade (AutoEQ + correction + user
EQ + notch + trim in a single band list). WDRC is **nonlinear**, so the
chain splits around it:

```
ring read → cascade A: AutoEQ bands (+ AutoEQ preamp)
          → AdaptiveCorrectionProcessor  (6-band WDRC)        ← NEW
          → DynamicBandProcessor         (Listening Comfort)
          → cascade B: user/preset EQ + tinnitus notch (+ global trim)
          → source-node output → balance mixers → sum → AUPeakLimiter → …
```

- **After AutoEQ:** the detector sees a headphone-flattened signal, so
  prescribed gains mean the same thing on every transducer (the same
  reasoning as notch-after-correction in the AutoEQ spec).
- **Before the user EQ and notch:** correction first, taste and notch on
  top — the static layer order, preserved.
- **The AUPeakLimiter remains the absolute output safety net**, and the
  post-EQ spectrum tap keeps feeding the dose tracker, so added WDRC boost
  is automatically counted (verified by test).

When the profile's mode is **Steady** (or it has no audiogram), the
processor is fully bypassed and the static `effectiveCorrectionBands` stay
in cascade B exactly as today — zero change for existing users. When
**Adaptive**, the static correction bands are *omitted* from cascade B (the
filterbank IS the correction) — never both.

### 4.2 Ownership & plumbing

- `CATapEngine` owns `leftAdaptive` / `rightAdaptive` processors (peers of
  the cascades and dynamics processors — the render block captures them
  strongly, no isolation hop). Sample rate plumbed in `applyTapPrep`.
- `SherlockEQAudioEngine.applyProfile` maps the profile → per-band
  `(G65, CR)` tables + mode flag + strength into both processors, and picks
  cascade B's band list per the mode. `flattenChain` / `teardownGraph` clear
  to bypass. `setReferenceMode` bypasses the processors alongside the
  cascades — Reference Mode stays *truly* unprocessed.
- **Live level anchor:** `AudioState` pushes `effectiveCalibrationOffsetDBA`
  into the processors whenever it changes (the existing
  `refreshVolumeDelta` already fires at every relevant moment). The
  gain rule (§1.2) makes a wrong-by-ε offset degrade gracefully: gains move
  along a bounded, capped curve, never discontinuously.
- **Model:** `HearingProfile.correctionMode: CorrectionMode` (`.steady` /
  `.adaptive`; `decodeIfPresent` → `.steady`). Rides profile JSON
  import/export automatically.

## 5. Interaction with the Phase-3 strength model

`effectiveCorrectionStrength` (target × ramp) scales the *entire*
level-dependent gain (§1.2) — one multiplier, same meaning in both modes:

- Acclimatization ramps Adaptive in over 21 days exactly like Steady.
- The Compensation slider stays the target-strength control.
- The §6 conflict check (notch vs correction) evaluates against the
  **moderate-level (65 dB SPL) gain family** — the anchor NAL-R values —
  which in Adaptive mode is precisely `effectiveCorrectionBands` already.
  No change needed; a comment records the equivalence.

## 6. UI

### 6.1 Mode selector (Audiogram screen)

A row below the chart (visible only when the profile has an audiogram):

> **Correction style:**  ● Steady   ○ Adaptive
>
> *Steady applies the same correction at every volume. Adaptive gives quiet
> sounds more help and loud sounds less — closer to how hearing actually
> works — using your playback calibration to judge levels. Start with
> Steady; try Adaptive when your calibration is set.*

Plus a status line when Adaptive is selected but the calibration is
`unanchored` (§7.3): *"Playback calibration hasn't been set — Adaptive is
running in its reduced-depth mode. Calibrate in Safe Listening for the full
effect."*

### 6.2 Level-aware previews (drawn = heard, extended)

- **`EQPreviewView` (Audiogram screen):** in Adaptive mode, draws the
  correction **family** — three curves at 50 / 65 / 85 dB SPL input
  (labeled "quiet / moderate / loud"), the 65 curve emphasized (it equals
  the Steady curve). Pure math from the §1 prescription — no DSP involved.
- **Canvas (Graphic + Parametric) Correction/Result layers:** continue to
  draw the moderate-level curves (unchanged), plus a **live adaptive
  overlay** — the current per-band gains from telemetry drawn as a dashed
  stroke, the Dynamics-overlay pattern (≤ 20 Hz, only while visible, only
  when deltas exceed 0.1 dB, `reduceMotion` snaps).

### 6.3 Framing (the product-review items)

- Name: **"Adaptive"** correction style (working name; alternatives §10).
  Never "compression", "WDRC", or "hearing-aid mode" in user-facing copy.
- The §4.1/§6.1 copy stays within the established posture: an audio
  personalization tool; no treatment claims; the existing not-a-hearing-aid
  footer applies. One new sentence of honesty: Adaptive's accuracy depends
  on the playback calibration, and says so where it's enabled.

## 7. Safety analysis (the section this spec exists for)

### 7.1 Failure-mode table

| Failure | Consequence | Mitigation |
|---|---|---|
| Calibration offset too HIGH (thinks audio is louder than it is) | Less gain than prescribed — under-correction | Benign direction; Steady-equivalent at worst |
| Calibration offset too LOW (thinks audio is quieter) | More gain, up to the caps | `maxExtraDB = 10` over NAL-R; `absoluteCapDB = 24`; AUPeakLimiter downstream; dose counts the boost |
| Calibration never performed (default 100 rule-of-thumb) | Systematic level error of unknown sign | **Reduced-depth mode** (§7.3): `maxExtraDB` drops to 4 dB until the user calibrates |
| Volume knob turned down mid-listening | Estimated level drops → gain rises (correct!) but bounded | Caps as above; change is smoothed, never a jump |
| Detector fooled by narrowband content | One band's gain misjudged | Per-band caps; 6 independent bands localize the error |
| Sudden loud onset during high-gain state | Momentary over-amplification | 5 ms attack; AUPeakLimiter brick-walls the sum |
| NaN / garbage in prescription inputs | Undefined gain | Gain computer clamps through finite bounds; non-finite → bypass band (unity), test-pinned |
| User A/B confusion (what am I hearing?) | Trust erosion | Reference Mode bypasses everything incl. WDRC; live overlay shows the moving gains |

### 7.2 Invariants (each is a test in §8)

1. Band insertion gain ≤ 24 dB absolutely, ≤ NAL-R + 10 (or + 4 uncalibrated) — for **any** input signal, offset, audiogram, and strength.
2. At a steady 65 dB SPL band input, Adaptive gain == Steady (NAL-R) gain within 0.5 dB.
3. Gain is monotonically non-increasing in input level.
4. All-bands-unity filterbank output == input within 0.5 dB, 20 Hz–20 kHz.
5. Reference Mode produces bit-identical passthrough.
6. L/R remain physically separate (the channel-separation regression suite applies).
7. Dose at the tracker reflects WDRC boost (engaged Adaptive on a quiet signal raises measured level).

### 7.3 Calibration gating

`volumeTrackingStatus`-independent, deliberately simple: if the user has
**never set** the calibration (no persisted `calibrationOffsetDBA` beyond
the default), Adaptive runs with `maxExtraDB = 4` — audibly adaptive, but
its error budget is a fraction of the anchor uncertainty. The §6.1 status
line says so and points at the calibration workflow. No hard block: a
rule-of-thumb-calibrated Adaptive-lite still beats Steady for comfort, and
a hard gate would just park users on the worse mode.

## 8. Testing plan

- **Filterbank:** unity flatness (invariant 4); crossover sum at each edge;
  state reset on SR change; denormal behavior after silence.
- **Prescription (pure):** anchor equivalence at 65 (invariant 2); CR
  mapping and clamps; knee behavior (constant below, tapered above);
  monotonicity property test across the level grid (invariant 3); caps
  under adversarial inputs incl. non-finite (invariants 1, NaN row);
  strength/ramp scaling; reduced-depth mode.
- **Processor:** ballistics within ±30 % of constants; smoothed gain steps
  ≤ deadband-adjacent (no zipper); bypass bit-exactness (invariant 5);
  no allocation in `process` (code review + instrument pass).
- **Integration:** applyProfile mode switch swaps static bands ↔ filterbank
  with no double-correction; Reference Mode; flatten/teardown; dose
  accounting (invariant 7); channel separation (invariant 6).
- **Listening pass (gates release):** speech at low/moderate/high volume —
  quiet dialogue lifts, loud passages comfortable, no pumping on music
  bass, no breathing on speech pauses; A/B Steady↔Adaptive at moderate
  level is a near-null.

## 9. Implementation order & effort

1. **Filterbank + prescription math (pure) + tests** — no engine wiring;
   the §7.2 invariants 1–4 all pass here. ≈ 1.5 sessions.
2. **Processor (detector + gain smoothing + RT plumbing) + tests.** ≈ 1 session.
3. **Engine integration** (ownership, applyProfile mapping, mode field,
   bypass coverage, offset push, telemetry). ≈ 1 session.
4. **UI** (mode selector, preview family, live overlay) + docs + listening
   pass. ≈ 1–1.5 sessions.

Total ≈ 4.5–5 sessions, each independently shippable behind the
default-Steady mode.

## 10. Open questions

| # | Question | Lean |
|---|---|---|
| 1 | Band count: 6 (this spec) vs 8 (full audiogram grid) | 6 — half-octave HTL detail folds into interpolated CR/G65 with < 2 dB consequence; 8 costs two more crossovers per ear for marginal fidelity |
| 2 | User-facing name: "Adaptive" vs "Dynamic" vs "Natural" | "Adaptive" — describes behavior without implying a medical modality |
| 3 | Low-level expansion below `kneeLow` (hiss management) in v1? | Defer — constant gain below knee is safe; expansion is a tuning knob once real-world feedback exists |
| 4 | Default mode for NEW audiograms once Adaptive proves out | Steady for v1; revisit after a release cycle of listening feedback |
| 5 | Should the Listening Check results page offer "enable Adaptive"? | Not in v1 — one new concept per flow; the Audiogram screen selector is discoverable enough |
| 6 | Per-band release tuning (syllabic vs slow compression) | Ship the §3 constants; they're in one type — the listening pass may retune |
