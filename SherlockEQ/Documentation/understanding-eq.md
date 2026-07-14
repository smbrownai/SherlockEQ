---
title: "Understanding EQ"
slug: "understanding-eq"
category: "Core EQ"
summary: "What equalization is, what frequency and gain mean, and how filters reshape sound."
keywords:
  - equalization
  - frequency
  - decibel
  - filter
  - basics
related:
  - graphic-eq
  - parametric-eq
  - gain-volume
  - vu-meters
---

# Understanding EQ

## What it does

Equalization adjusts the relative loudness of different **frequencies** in a
sound. Bass is low frequency, treble is high frequency, and an equalizer lets
you turn regions of that range up or down without affecting the others.

## Why it exists

No playback chain is perfectly flat. Speakers, headphones, rooms, and ears all
emphasize some frequencies and suppress others. EQ lets you compensate — to
match a preference, correct a device, or adjust for how you hear.

## How to use it

Frequency is measured in **hertz (Hz)** — humans hear roughly 20 Hz to
20,000 Hz (20 kHz). Level changes are measured in **decibels (dB)**: positive
values boost, negative values cut. The decibel scale is logarithmic: +10 dB is
roughly a doubling of *perceived loudness*, +6 dB doubles the sound pressure,
and a few decibels is an audible but not drastic change.

A **filter** is one EQ move. Common shapes:

- **Peaking (bell):** boosts or cuts a band centered on a frequency. Its width is set by **Q** — higher Q is narrower.
- **Shelf:** lifts or lowers everything above (high shelf) or below (low shelf) a corner frequency.
- **Notch:** a deep, narrow cut, used to remove a specific tone.

## What changes in the audio

EQ is a **linear** process: it re-weights frequencies that are already present.
It cannot add detail that wasn't recorded, and a large boost where there is no
signal just raises noise.

## How it interacts with other settings

In SherlockEQ, EQ runs **per ear** before [balance](help:balance) and the
master [gain](help:gain-volume) stage. Boosting bands raises overall level, so
EQ and gain interact — see [Safety](help:safety-limits).

## Recommended uses

- Tame a harsh or boomy device with gentle cuts.
- Lift presence for clearer speech.
- Build a [profile](help:profiles) per listening situation.

## Things to avoid

- Large boosts that cause [clipping](help:safety-limits) or fatigue.
- "Fixing" every dip — broad, gentle moves usually sound more natural than many narrow ones.

## Technical notes

SherlockEQ implements each band as a biquad filter using the widely used Audio
EQ Cookbook formulas.[^1] Bands are applied as a cascade per ear, so left and
right signal paths stay physically separate.

## Limitations

EQ corrects frequency balance, not distortion, timing, or recording quality.

## References

[^1]: Bristow-Johnson, Robert. "Cookbook formulae for audio EQ biquad filter coefficients." Audio EQ Cookbook. https://www.w3.org/TR/audio-eq-cookbook/
