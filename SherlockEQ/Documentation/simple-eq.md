---
title: "Simple EQ: Bass, Mid, Treble"
slug: "simple-eq"
category: "Core EQ"
summary: "Three broad controls for quick tone shaping, and how they map to the underlying EQ."
keywords:
  - simple
  - bass
  - mid
  - treble
  - tone
  - shelf
related:
  - parametric-eq
  - understanding-eq
  - audiogram-profiles
  - gain-volume
---

# Simple EQ: Bass, Mid, Treble

## What it does

Simple EQ reduces tone shaping to three familiar controls:

- **Bass** — low frequencies, the weight and warmth (roughly below ~250 Hz).
- **Mid** — the midrange where most voices and instruments live (~250 Hz–5 kHz).
- **Treble** — high frequencies, the air and detail (roughly above ~5 kHz).

## Why it exists

Most everyday adjustments are broad — "a bit warmer", "less harsh". Three
controls get you there without learning frequencies or Q.

## How to use it

Make small moves first (±2–4 dB). If you find yourself wanting more precision,
switch to [Parametric EQ](help:parametric-eq).

## What changes in the audio

In SherlockEQ, **Bass** and **Treble** are implemented as **shelf filters**
(low shelf around 250 Hz, high shelf around 5 kHz) and **Mid** as a broad
peaking filter. Shelves lift or lower everything beyond their corner; the mid
bell affects a wide band around its center.

## How it interacts with other settings

- Simple, Parametric, and other EQ modes write to the **same underlying per-ear band storage**, so switching modes is non-destructive — bands you set elsewhere are kept, just hidden.
- Boosts raise overall level and interact with master [gain](help:gain-volume) and [clipping](help:safety-limits).
- Differs from [audiogram profiles](help:audiogram-profiles), which derive a frequency-specific shape rather than three broad regions.

## Recommended uses

- Quick comfort adjustments for a given device or room.
- A starting point you later refine with parametric bands.

## Things to avoid

- Large simultaneous bass + treble boosts (the "smile" curve) — they sound impressive briefly but raise level and fatigue quickly.

## Technical notes

The three controls map onto cookbook shelf and peaking biquads — the same math
the parametric and audiogram paths use, so the rendered curve always matches
what you hear.

## Limitations

Three bands can't fix a narrow problem (a single resonant peak). Use
[Parametric EQ](help:parametric-eq) for that.

## References

See [References](help:references).
