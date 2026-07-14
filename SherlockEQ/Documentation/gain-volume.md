---
title: "Volume / Gain"
slug: "gain-volume"
category: "Core EQ"
summary: "How SherlockEQ's master gain differs from system volume, and why boosting can clip."
keywords:
  - gain
  - volume
  - level
  - clipping
  - headroom
  - loudness
related:
  - safety-limits
  - vu-meters
  - graphic-eq
  - balance
---

# Volume / Gain

## What it does

The **master gain** sets the overall output level of the processed signal,
applied *after* EQ and balance. It is separate from your Mac's **system
volume**.

## Why it exists

EQ boosts add energy to the signal. A dedicated gain stage lets you bring the
overall level back down after boosting (to avoid clipping) or add a little
make-up gain when you've mostly cut. It also gives you a single, predictable
output trim independent of whatever the system volume is doing.

## How to use it

- Set EQ first, then use gain to land the overall level where you want it.
- If you boosted bands, **reduce** gain to restore headroom.
- Use the [VU Meters](help:vu-meters) to watch where you actually are.

## What changes in the audio

Gain is a simple multiplication of the signal. Positive gain makes everything
louder; negative gain makes everything quieter. Unlike EQ, it changes all
frequencies equally.

## How it interacts with other settings

- **EQ boosts + gain:** a +6 dB band plus +6 dB master gain can stack to +12 dB at that frequency, which is a fast route to clipping.
- **Cutting vs. boosting:** cutting bands and adding modest make-up gain preserves headroom better than boosting bands. **Cutting is generally safer than boosting.**
- **Balance:** [balance](help:balance) is applied per ear before master gain; gain then scales both ears together.
- **Limiter:** SherlockEQ runs a peak limiter near the end of the chain as a safety net, but a limiter constantly catching peaks will audibly pump — it is not a substitute for leaving headroom.

## Recommended uses

- Restoring level after corrective cuts.
- A single global output trim shared across every profile. (For a trim that
  belongs to one [profile](help:profiles) and swaps with it, use that profile's
  **Global trim** control instead — master gain is not per-profile.)

## Things to avoid

- Pushing gain to mask a quiet source — raise the source or system volume instead.
- Stacking large boosts and large gain. If the meters hit the top, back off.

## Technical notes

Gain is applied as a decibel offset on a dedicated stage. Digital audio has a
hard ceiling (0 dBFS); signal that exceeds it is **clipped** — flattened — which
sounds like harsh distortion. Headroom is the margin you leave below that
ceiling.

## Limitations

The on-screen level is in **dBFS** (digital full scale), not calibrated
loudness in your room. SherlockEQ is not a sound-level meter. See
[Safety](help:safety-limits).

## References

See [References](help:references).
