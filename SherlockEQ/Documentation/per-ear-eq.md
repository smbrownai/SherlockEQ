---
title: "Per-Ear EQ"
slug: "per-ear-eq"
category: "Hearing-Aware Features"
summary: "Independent left and right correction — how it differs from balance, and its limits."
keywords:
  - per-ear
  - left
  - right
  - asymmetric
  - channel
  - hearing
related:
  - balance
  - audiogram-profiles
  - parametric-eq
  - safety-limits
---

# Per-Ear EQ

## What it does

Per-Ear EQ lets the left and right channels carry **different EQ shapes**. When
enabled, each ear has its own band list, so you can correct a treble dip on one
side without touching the other.

## Why it exists

Hearing is often **asymmetric** — the two ears can differ in how they perceive
particular frequencies. A single stereo EQ can't address that; per-ear EQ can.

## How to use it

Turn on **Separate L+R** for the profile. The EQ views then show independent
left and right controls. Adjust each side to taste. With it off, both ears
share one shape (the common case).

## What changes in the audio

Left and right are processed through **physically separate filter chains**, so
a change on one side does not affect the other.

## How it interacts with other settings

- **Per-Ear EQ vs. [Balance](help:balance):** balance changes overall *level* on one side; per-ear EQ changes the *frequency shape* of one side. They solve different problems and can be used together.
- Feeds from the same per-ear band storage used by [Simple](help:simple-eq) and [Parametric](help:parametric-eq) modes, plus any [audiogram](help:audiogram-profiles) shaping and [tinnitus notch](help:tinnitus-tone-matching).
- The per-profile setting; different [profiles](help:profiles) can choose linked or separate.

## Recommended uses

- Compensating for a known left/right difference in perceived tone.
- Headphone listening, where each driver sits directly at one ear.

## Things to avoid

- Guessing large per-ear corrections from memory. Make small changes and compare against a neutral [reference](help:gain-volume).
- Treating per-ear EQ as a substitute for a fitted hearing aid — it is not.

## Technical notes

On speakers, both ears hear both channels (acoustic crosstalk), so per-ear EQ
is most precise on headphones, where each channel reaches mainly one ear.

## Limitations

This is consumer self-adjustment, not a clinical fitting. SherlockEQ has no
way to measure your ears; it applies the correction you dial in.

## Not medical advice

SherlockEQ is **not a hearing aid** and not a medical device. It does not
diagnose or treat hearing loss. Sudden or one-sided hearing change can be a
medical sign — consult a licensed hearing-care professional or physician
promptly.

## Research context

Asymmetric and sensorineural hearing loss are well documented in the audiology
literature, and clinical correction (amplification, frequency shaping) is
performed by fitting hearing aids to measured thresholds with prescriptive
methods.[^1] Consumer EQ can mimic the *direction* of such shaping but lacks
the measurement, compression, and verification of a clinical fit.

## References

[^1]: Dillon, Harvey. *Hearing Aids*, 2nd ed. Boomerang Press / Thieme, 2012.
