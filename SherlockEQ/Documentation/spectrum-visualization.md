---
title: "Spectrum & Visualization"
slug: "spectrum-visualization"
category: "Metering & Visualization"
summary: "The live frequency analyzer, 1/3-octave bars, peak callouts, and how to read them while you EQ."
keywords:
  - spectrum
  - analyzer
  - fft
  - bars
  - octave
  - peaks
  - visualization
related:
  - vu-meters
  - parametric-eq
  - understanding-eq
  - safety-limits
---

# Spectrum & Visualization

## What it does

The spectrum view shows, in real time, how much energy the audio carries at
each **frequency** — a moving picture of the bass, mids, and treble in whatever
you're listening to. It can display a smooth spectrum, **1/3-octave bars**, and
**peak callouts** that label prominent tones.

## Why it exists

Seeing the spectrum makes EQ decisions concrete: you can spot a resonant peak,
confirm a boost landed where you intended, and watch how your changes reshape
the sound.

## How to use it

- Toggle layers (input vs. output, EQ curve, safety overlay, peaks) to compare before/after.
- Hover for a readout of frequency and level at the cursor.
- Watch where energy concentrates before deciding where to cut or boost.

## What changes in the audio

Nothing — visualization is **read-only**. It analyzes the signal but does not
alter it.

## How it interacts with other settings

- Overlays the [parametric EQ](help:parametric-eq) curve so you can match a correction to what you see.
- Shares the safe-listening thresholds with the [VU meters](help:vu-meters) and [safety](help:safety-limits) view.
- Reflects the processed (post-EQ) signal.

## Recommended uses

- Identifying a narrow resonance to notch.
- Verifying a [headphone correction](help:headphone-correction-autoeq) or [audiogram](help:audiogram-profiles) shape.

## Things to avoid

- "EQ-ing to a flat line" — a flat spectrum is not the goal; music isn't flat, and your ears aren't either.
- Reading instantaneous bin levels as calibrated loudness.

## Technical notes

The analyzer uses a windowed discrete Fourier transform with smoothing and
log-frequency binning; peak callouts use prominence detection with hysteresis
so labels don't flicker. FFT bin energy reads lower than time-domain RMS, which
the safety overlay compensates for.

## Limitations

Frequency resolution is limited at low frequencies (few bins per octave), and
the display is a short-time estimate, not a precise measurement instrument.

## References

See [References](help:references) for DSP and metering sources.
