---
title: "Graphic EQ"
slug: "graphic-eq"
category: "Core EQ"
summary: "A twelve-band graphic equalizer on the audiometric grid — the everyday EQ surface, with full Parametric one click away."
keywords:
  - advanced
  - graphic
  - equalizer
  - twelve band
  - octave
  - sliders
related:
  - graphic-eq
  - parametric-eq
  - understanding-eq
---

# Graphic EQ

## What it does

Graphic EQ is a **twelve-band graphic equalizer**: a row of vertical sliders
on the audiometric grid — the standard octave centers plus 3 and 6 kHz, the
same frequencies your [audiogram](help:audiogram-profiles) is measured at.
It's the everyday surface: enough resolution to shape a curve across the
whole spectrum without managing individual filter parameters. For arbitrary
bands, use [Parametric EQ](help:parametric-eq).

The twelve bands are fixed at:

**31.5 · 63 · 125 · 250 · 500 Hz · 1 · 2 · 3 · 4 · 6 · 8 · 16 kHz**

Each is a one-octave-wide peaking filter, so neighbouring sliders blend into a
smooth overall shape.

## Why it exists

A graphic EQ is the familiar "row of sliders" everyone recognises. When you want
to draw a tone curve by feel — scoop the mids, lift the top — but three bands
isn't enough, this is the fastest tool.

## How to use it

- Open the **Equalizer** screen and choose **Graphic** in the surface control at the top (next to the screen title).
- Drag sliders to shape the curve, or start from the **Preset** button: a small set named for outcomes — Clearer voices, Music balance, Gentle listening, Reduce boom, Reduce harshness. The button shows **Custom** whenever your sliders diverge from every preset.
- The **Tone flavors** button beside it holds genre / taste curves (Warm, Bright, Rock, Jazz, …) — a matter of preference, not hearing correction. They stack on top of your profile's correction.
- Turn on the **Tone guide** to label what each band affects — Rumble, Bass, Warmth, Voice body, Clarity, Sibilance, Air.
- Move in small steps; each slider reads out in dB. **Reset to Flat** returns every band to zero.

## What changes in the audio

Each slider drives a one-octave peaking biquad at its center frequency, applied
per ear in the same cascade as the rest of the equalizer. The twelve bells sum into the
curve you see drawn over the spectrum.

## How it interacts with other settings

- Graphic and Parametric write to the **same per-ear band storage** — switching surfaces is non-destructive. Filters the sliders can't represent (from Parametric, an older version's modes, or the command line) appear in an **Other filters** row, which can convert them onto the sliders or take you to Parametric — nothing active is ever invisible.
- When your profile has an [audiogram](help:audiogram-profiles) correction and/or a [headphone correction](help:headphone-correction-autoeq), an **"Additional correction is active"** note appears. That correction runs beneath your graphic bands and is already included in the curve drawn over the spectrum — you edit it on the Audiogram screen and in the profile's headphone settings, not on these sliders.
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
frequency, change its Q, or use a shelf/notch/pass filter, use
[Parametric EQ](help:parametric-eq).

## References

See [References](help:references).
