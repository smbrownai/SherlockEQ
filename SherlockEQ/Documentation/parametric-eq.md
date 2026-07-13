---
title: "Parametric EQ"
slug: "parametric-eq"
category: "Core EQ"
summary: "Precise control of frequency, gain, Q, and filter type — including stacked and per-ear bands."
keywords:
  - parametric
  - frequency
  - gain
  - Q
  - bandwidth
  - notch
  - shelf
  - peaking
related:
  - simple-eq
  - per-ear-eq
  - understanding-eq
  - safety-limits
---

# Parametric EQ

## What it does

Parametric EQ gives you full control over each band: its **frequency**, its
**gain**, its **Q** (bandwidth), and its **filter type**. You can stack
multiple bands to build any response shape. In a profile's **Tuning** section
this mode is selected as **Expert**.

## Why it exists

Broad tone controls can't address a specific resonance, a narrow harsh region,
or a precise correction target. Parametric bands let you place a move exactly
where it's needed.

## How to use it

For each band, set:

- **Frequency** — where the band is centered, in Hz.
- **Gain** — how much to boost (+) or cut (−), in dB.
- **Q / bandwidth** — how wide the band is. High Q is narrow and surgical; low Q is broad and gentle.
- **Filter type:**
  - **Peaking (bell)** — boost/cut around a center frequency.
  - **Low shelf / high shelf** — lift or lower everything below/above a corner.
  - **Notch** — deep, narrow cut to remove a tone (see [Tinnitus Tone Matching](help:tinnitus-tone-matching)).
  - **Low-pass / high-pass / band-pass** — pass only part of the spectrum.

You can drag bands directly on the parametric canvas, which overlays the live
spectrum so you can see what you're correcting.

## What changes in the audio

Each band is a biquad filter; the chain is the product of all enabled bands'
responses, applied per ear.

## How it interacts with other settings

- Bands stack: overlapping boosts **add up**, which can clip. Watch headroom.
- Shares per-ear band storage with [Simple](help:simple-eq), [Speech](help:speech-eq), and [Advanced](help:advanced-eq) EQ. Audiogram correction and the tinnitus notch are applied as separate per-ear layers on top, not stored in the same band list.
- With [Per-Ear EQ](help:per-ear-eq) on, left and right hold independent band lists.

## Recommended uses

- A narrow cut to tame one resonant peak (more natural than a broad cut).
- Gentle shelves to rebalance overall warmth or air.
- Matching a target curve from an [audiogram](help:audiogram-profiles) or [headphone correction](help:headphone-correction-autoeq).

## Things to avoid

- Many large boosts — each one costs headroom and stacks toward [clipping](help:safety-limits).
- Extremely high-Q boosts, which ring and sound unnatural.
- "Mirroring" every spectrum dip — dips are often less audible than the cost of correcting them.

## Technical notes

Safe gain staging: prefer **cuts** to boosts, and add make-up [gain](help:gain-volume)
only as needed. Coefficients follow the Audio EQ Cookbook;[^1] gain is clamped
to a safe range internally to prevent numerical instability.

## Limitations

Parametric EQ corrects steady-state frequency balance. It does not address
phase problems in the source, time-domain artifacts, or distortion.

## References

[^1]: Bristow-Johnson, Robert. "Cookbook formulae for audio EQ biquad filter coefficients." Audio EQ Cookbook. https://www.w3.org/TR/audio-eq-cookbook/
