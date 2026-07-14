---
title: "Advanced EQ"
slug: "advanced-eq"
category: "Core EQ"
summary: "A twelve-band graphic equalizer on the audiometric grid — more control than Simple, simpler than Expert."
keywords:
  - advanced
  - graphic
  - equalizer
  - twelve band
  - octave
  - sliders
related:
  - simple-eq
  - speech-eq
  - parametric-eq
  - understanding-eq
---

# Advanced EQ

## What it does

Advanced EQ is a **twelve-band graphic equalizer**: a row of vertical sliders
on the audiometric grid — the standard octave centers plus 3 and 6 kHz, the
same frequencies your [audiogram](help:audiogram-profiles) is measured at. It sits between [Simple
EQ](help:simple-eq) (three broad controls) and [Expert / Parametric
EQ](help:parametric-eq) (arbitrary bands) — enough resolution to shape a curve
across the whole spectrum, without managing individual filter parameters.

The twelve bands are fixed at:

**31.5 · 63 · 125 · 250 · 500 Hz · 1 · 2 · 3 · 4 · 6 · 8 · 16 kHz**

Each is a one-octave-wide peaking filter, so neighbouring sliders blend into a
smooth overall shape.

## Why it exists

A graphic EQ is the familiar "row of sliders" everyone recognises. When you want
to draw a tone curve by feel — scoop the mids, lift the top — but three bands
isn't enough, this is the fastest tool.

## How to use it

- Set a profile's EQ mode to **Advanced** in the profile's Tuning section, then open the **Equalizer** screen.
- Drag sliders to shape the curve, or start from a **preset** (general shapes, music genres, and corrective curves) and tweak.
- Move in small steps; the sliders read out in dB.

## What changes in the audio

Each slider drives a one-octave peaking biquad at its center frequency, applied
per ear in the same cascade as the other EQ modes. The ten bells sum into the
curve you see drawn over the spectrum.

## How it interacts with other settings

- Advanced, Simple, Speech, and Expert all write to the **same per-ear band storage** — switching modes is non-destructive. A hint appears if the current mode is hiding bands set elsewhere.
- Boosts raise overall level and interact with master [gain](help:gain-volume) and [clipping](help:safety-limits).
- Turn on [Per-Ear EQ](help:per-ear-eq) to set the left and right sliders independently.

## Recommended uses

- Broad tone shaping across the full range when three bands is too coarse.
- Genre or room curves where you want octave-by-octave control.

## Things to avoid

- Sawtooth settings (every other slider up/down) — they sound phasey and raise level for little benefit.
- Large boosts stacked across many bands — watch headroom and clipping.

## Limitations

The band centers and one-octave width are fixed. To place a band at an arbitrary
frequency, change its Q, or use a shelf/notch/pass filter, use [Expert /
Parametric EQ](help:parametric-eq).

## References

See [References](help:references).
