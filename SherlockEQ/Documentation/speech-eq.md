---
title: "Speech EQ"
slug: "speech-eq"
category: "Core EQ"
summary: "Six named bands tuned to the frequencies that carry voice, for dialogue and podcast clarity."
keywords:
  - speech
  - voice
  - dialogue
  - podcast
  - vocal
  - clarity
  - sibilance
related:
  - simple-eq
  - advanced-eq
  - parametric-eq
  - understanding-eq
---

# Speech EQ

## What it does

Speech EQ gives you six controls, each named for the part of the voice it
affects, instead of raw frequencies. It's built for making **talking** clearer —
podcasts, audiobooks, calls, TV dialogue — without learning the underlying EQ.

The six bands are:

- **Low rumble** (60 Hz, low shelf) — cut to remove hum and room boom under the voice.
- **Vocal warmth** (200 Hz) — body and fullness; too much sounds muddy.
- **Vocal body** (800 Hz) — the core of the voice; the "chest" of the sound.
- **Consonant clarity** (2.5 kHz) — intelligibility of consonants; a small lift makes speech easier to follow.
- **Sibilance** (6 kHz) — the "ess" and "sh" sounds; cut if they're harsh.
- **Air & brilliance** (12 kHz, high shelf) — openness and detail at the very top.

## Why it exists

Most "I can't quite make out the dialogue" problems live in two or three narrow
regions of the voice. Naming those regions lets you fix them directly — lift
**Consonant clarity**, ease **Sibilance** — instead of hunting across a full
parametric EQ.

## How to use it

- Set a profile's EQ mode to **Speech** in the profile's Tuning section, then open the **Equalizer** screen.
- Start from a **preset** (Audiobook, Podcast, TV dialogue, Voice call, and so on) and adjust from there.
- Make small moves first (±2–4 dB). A little **Consonant clarity** goes a long way.
- Each slider has a one-line description you can dismiss once you know it.

## What changes in the audio

Each band is a cookbook biquad — **Low rumble** and **Air & brilliance** are
shelves, the four middle bands are peaking filters — applied per ear in the same
biquad cascade the other EQ modes use. The drawn curve matches what you hear.

## How it interacts with other settings

- Speech, Simple, Advanced, and Expert all write to the **same per-ear band storage**, so switching modes is non-destructive — bands you set in another mode are kept, just hidden. A hint appears if the current mode is hiding bands you set elsewhere.
- Boosts raise overall level and interact with master [gain](help:gain-volume) and [clipping](help:safety-limits).
- For dynamic, signal-following help with harsh or sibilant voices, see [Listening Comfort](help:listening-comfort).

## Recommended uses

- Spoken-word content: audiobooks, podcasts, lectures, video calls.
- Pulling dialogue forward in TV and film mixes.

## Things to avoid

- Over-lifting **Consonant clarity** and **Sibilance** together — speech gets thin and fatiguing.
- Big **Vocal warmth** boosts on calls — they muddy intelligibility.

## Limitations

Six fixed bands are a deliberate simplification. For an arbitrary frequency, Q,
or filter type, use [Advanced EQ](help:advanced-eq) or [Expert / Parametric
EQ](help:parametric-eq).

## References

See [References](help:references).
