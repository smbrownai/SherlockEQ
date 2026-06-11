---
title: "Balance"
slug: "balance"
category: "Core EQ"
summary: "Left/right level offset — how it differs from per-ear EQ and when to use each."
keywords:
  - balance
  - left
  - right
  - pan
  - stereo
  - asymmetric
related:
  - per-ear-eq
  - gain-volume
  - audiogram-profiles
  - output-devices
---

# Balance

## What it does

Balance shifts the relative **level** between the left and right channels. Center
is equal; moving it attenuates one side relative to the other.

## Why it exists

Sometimes one side is simply too loud — a desk against a wall, an ear that
perceives level differently, or content mixed off-center. Balance is the
quickest fix for an overall level difference between sides.

## How to use it

Nudge toward the quieter side until the image feels centered. Use the recenter
control to return to neutral.

## What changes in the audio

Balance applies a level attenuation to one channel. It is **broadband** — it
changes the loudness of that whole side equally across all frequencies.

## How it interacts with other settings

- **Balance vs. [Per-Ear EQ](help:per-ear-eq):** balance changes *overall level* on one side; per-ear EQ changes the *frequency shape* of one side. If one ear hears highs differently, balance can't fix that — per-ear EQ can.
- **Not an audiogram correction:** an [audiogram](help:audiogram-profiles) describes frequency-dependent hearing differences, which balance alone cannot address.
- Applied per ear before the master [gain](help:gain-volume) stage.

## Recommended uses

- Compensating for an off-center speaker setup.
- A small, comfortable level offset between sides.
- Mono-routing considerations for content mixed to one channel.

## Things to avoid

- Using heavy balance to "correct hearing" — that's the job of per-ear EQ and, clinically, a hearing professional.
- Large offsets on headphones, which can be fatiguing and mask the stereo image.

## Technical notes

Balance is implemented as a linear level scale on the per-ear mixer stage,
chosen because it gives clean channel attenuation without leaking signal
across channels.

## Limitations

Balance cannot separate or re-pan elements within a mix; it only sets the
overall left/right level relationship.

## Not medical advice

A persistent need for strong balance correction can reflect a hearing
difference worth discussing with a licensed hearing-care professional.
SherlockEQ does not diagnose anything.

## References

See [References](help:references).
