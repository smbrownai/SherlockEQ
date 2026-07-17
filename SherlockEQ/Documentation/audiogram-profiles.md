---
title: "Audiogram & Hearing Profiles"
slug: "audiogram-profiles"
category: "Hearing-Aware Features"
summary: "How SherlockEQ uses audiogram-like inputs to shape a per-ear listening profile — and why that is not a clinical correction."
keywords:
  - audiogram
  - hearing
  - thresholds
  - hearing level
  - presbycusis
  - hearing profile
  - per-ear EQ
related:
  - per-ear-eq
  - safety-limits
  - parametric-eq
  - profiles
---

# Audiogram & Hearing Profiles

## What it does

The Audiogram screen lets you enter approximate **hearing thresholds** per ear
across frequencies, and uses them to suggest a per-ear EQ shape — a personal
listening profile that lifts regions where you've indicated reduced
sensitivity.

## Why it exists

If you hear high frequencies less well, a flat playback can feel dull or
unclear. Shaping playback toward where you need more can make everyday
listening more comfortable — for music, video, and speech.

## How to use it

Enter, for each frequency and ear, the level at which you can just detect a
tone (the **threshold**). SherlockEQ plots these on a chart and previews the
suggested EQ. You can then refine the result with [Parametric EQ](help:parametric-eq).

If you have a real audiogram from a clinic, use it as a guide for entry — but
read the limitations below before treating the result as a correction.

## Background: what an audiogram is

An audiogram measures **air-conduction thresholds**: the quietest tone you can
detect at each test frequency (commonly 250 Hz to 8 kHz), expressed in
**decibels Hearing Level (dB HL)** — a scale referenced to normal-hearing young
adults, not to absolute sound pressure.[^1] Higher dB HL means a higher (worse)
threshold. Age-related high-frequency loss (**presbycusis**) and
**sensorineural** loss are typical patterns.[^2]

## What changes in the audio

SherlockEQ converts your entered thresholds into per-ear EQ bands and applies
them through the same per-ear filter chain as the rest of the equalizer.

## No audiogram? Run the Listening Check

Most people don't have a clinical audiogram — the **Listening Check** (on the
Audiogram screen) estimates your thresholds in about five minutes: quiet
pulsing tones per ear, and you press a button whenever you hear one. It uses
the same procedure an audiologist uses, minus the calibrated booth, and its
result powers the correction exactly like manual entry. Requirements:
headphones (built-in speakers are blocked), a quiet room, and leaving the
volume alone during the check. It is an **estimate** — it cannot diagnose
anything, and persistent hearing concerns belong with a professional.

## Acclimatization

The first time an audiogram is applied to a profile, the adjustment starts at
**60 % strength and rises to 100 % over 21 days** — the same gradual easing
hearing-care professionals use, because an unaccustomed ear finds a full
prescription harsh at first. A chip shows which day you're on and the strength
currently applied; **Skip to full strength** ends the ramp any time. The
Adjustment strength slider sets your long-term target — the ramp scales it,
never overrides it.

## Adjustment style: Steady vs Adaptive

Below the threshold chart you can choose how the hearing adjustment is applied
(SherlockEQ calls this a *hearing adjustment*, not a "correction", because it's
a comfort-oriented shaping tuned by ear — not a verified clinical fitting):

- **Steady** (the default) applies the same adjustment at every volume — a
  fixed EQ shape derived from your thresholds.
- **Adaptive** gives quiet sounds more help and loud sounds less — closer to
  how hearing actually works. Sensorineural loss compresses the range between
  "can't hear it" and "plenty loud" (recruitment), so a fixed boost that
  rescues quiet detail can make loud passages uncomfortable. Adaptive follows
  the level in six frequency bands and eases the boost off as content gets
  louder, anchored so that at moderate levels it equals the Steady curve.

Adaptive judges "quiet" and "loud" using your **playback calibration** from
Safe Listening. Until you calibrate, it runs in a reduced-depth mode — the
level-dependent part is kept small because its level estimate is a guess. The
preview chart switches to a family of three curves (quiet / moderate / loud)
so you can see exactly how the adjustment moves with level.

Start with Steady; try Adaptive when your calibration is set and you notice
quiet passages need more help than loud ones.

## How it interacts with other settings

- Feeds [Per-Ear EQ](help:per-ear-eq); left and right are shaped independently.
- Stacks with [Graphic](help:graphic-eq) / [Parametric](help:parametric-eq) bands and any [headphone correction](help:headphone-correction-autoeq).
- Boosting where hearing is reduced raises level — mind [gain](help:gain-volume) and [safety](help:safety-limits).
- Saved as part of a [profile](help:profiles).

## Why an audiogram does not become an EQ curve directly

This is the most important point on this page. **A hearing adjustment is not
"add the inverse of the audiogram."** Several reasons:

- **dB HL is not dB of EQ gain.** Thresholds are referenced to normal hearing, not to your playback's digital level, so they don't translate one-to-one into boost.
- **Loudness recruitment.** In sensorineural loss, perceived loudness can grow abnormally fast above threshold — quiet sounds are inaudible but loud sounds are as loud (or uncomfortable) as ever.[^3] Applying full inverse gain can make sounds *too loud* and uncomfortable, which is why clinical fittings use frequency-dependent **compression**, not flat boost.
- **Output level and headphones matter.** The same EQ at a different volume or on a different device lands differently; thresholds measured clinically were taken under calibrated conditions yours are not.

For these reasons SherlockEQ applies a **conservative, partial** shaping and
exposes it for you to refine by ear — it deliberately does not apply full
inverse gain.

## Recommended uses

- A gentle, comfortable lift toward frequencies you find dull.
- A starting profile you fine-tune by listening.

## Things to avoid

- Entering a clinical audiogram and expecting a hearing-aid-equivalent result.
- Large boosts in regions of significant loss — comfortable is the goal, not "maximum."
- Sudden big changes; adjust gradually and stop if anything is uncomfortable.

## Limitations

SherlockEQ cannot measure your hearing, cannot apply calibrated SPL, and does
not implement the multiband compression or real-ear verification a clinical
fitting uses. Results vary by person, content, level, and device.

## Not medical advice

SherlockEQ is **not a medical device** and **not a hearing aid**. It does not
diagnose, treat, cure, or prevent hearing loss. An audiogram should be obtained
and interpreted by a licensed audiologist. If you have hearing loss, sudden
hearing change, ear pain, or dizziness, consult a hearing-care professional or
physician.

## Research context

Audiometric procedures and the dB HL reference are defined in clinical
standards and texts.[^1] Prescriptive fitting methods (e.g. NAL-NL2, DSL)
translate measured thresholds into frequency- and level-dependent gain using
loudness models and compression — not a simple inverse curve — and verify the
result with real-ear measurement.[^4][^3]

SherlockEQ derives its suggested shape from **NAL-R** (National Acoustic
Laboratories, Revised; Byrne & Dillon 1986), the linear predecessor of NAL-NL2,
scaled down by the Adjustment strength control. It is a conservative starting
point for tuning by ear — not a verified clinical fitting.

## References

[^1]: American Speech-Language-Hearing Association. "Pure-Tone Testing." ASHA Practice Portal. https://www.asha.org/practice-portal/clinical-topics/

[^2]: World Health Organization. "Deafness and hearing loss" (fact sheet), 2024. https://www.who.int/news-room/fact-sheets/detail/deafness-and-hearing-loss

[^3]: Moore, Brian C. J. *Cochlear Hearing Loss: Physiological, Psychological and Technical Issues*, 2nd ed. Wiley, 2007.

[^4]: Keidser, G., Dillon, H., et al. "The NAL-NL2 Prescription Procedure." *Audiology Research*, 2011. https://doi.org/10.4081/audiores.2011.e24
