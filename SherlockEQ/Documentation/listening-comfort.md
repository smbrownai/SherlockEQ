---
title: "Listening Comfort"
slug: "listening-comfort"
category: "Hearing-Aware Features"
summary: "Three adaptive processors that ease harshness and sibilance and lift speech only when it's needed."
keywords:
  - listening comfort
  - dynamic
  - speech presence
  - harshness
  - sibilance
  - de-ess
  - adaptive
related:
  - speech-eq
  - parametric-eq
  - per-ear-eq
  - safety-limits
---

# Listening Comfort

## What it does

Listening Comfort is a set of three **adaptive** processors. Unlike the EQ
modes, which apply a fixed curve all the time, these watch the signal and act
**only when their target appears** — then back off again. They're found under
the **Listening Comfort** entry in the sidebar.

- **Speech Presence** — gently lifts the speech range *while someone is talking*, then relaxes, so dialogue sits forward without permanently brightening music.
- **Harshness Control** — tames hard, edgy peaks in the upper midrange as they occur, smoothing fatiguing material.
- **Sibilance Tamer** — reduces harsh "ess" and "sh" sounds (a de-esser) only on the syllables that need it.

Speech Presence is the one that **boosts**; Harshness Control and Sibilance
Tamer only ever **reduce**.

## Why it exists

Some problems are intermittent — a sibilant narrator, a brittle cymbal, dialogue
that ducks under the music. A static EQ cut to fix them would dull everything
else. An adaptive processor only engages on the offending moments and leaves the
rest of the audio alone.

## How to use it

Each processor has the same simple controls:

- An **enable** toggle.
- **Strength** — how much it can do at most (e.g. how many dB it pulls down, or lifts).
- **Sensitivity** — how readily it engages: higher reacts to more material, lower only to the strongest cases.
- An **activity meter** showing, live, how much it's working at this instant (in dB, with `idle` when it isn't) — so you can see it respond to the audio.

Start with a feature enabled at moderate strength, play typical material, and
watch the meter. Raise **Sensitivity** if it isn't catching enough; lower
**Strength** if the effect is audible on material that didn't need it.

## What changes in the audio

Each feature is a single adaptive band in the per-ear chain: a detector tracks
the target region, and a smoothed gain is applied to a bell at that frequency.
Because the gain follows the signal with a short release, the effect comes and
goes with the audio rather than being baked into a fixed curve.

## How it interacts with other settings

- Runs alongside your chosen EQ mode and [headphone correction](help:headphone-correction-autoeq); it shapes dynamically on top of those static curves.
- With [Per-Ear EQ](help:per-ear-eq) on, each feature can be set independently for the left and right ears; otherwise one control drives both.
- For *static* speech shaping (always-on, not signal-following), use [Speech EQ](help:speech-eq) instead — the two complement each other.
- Reductions lower level on their moments; Speech Presence's lift interacts with master [gain](help:gain-volume) and [clipping](help:safety-limits) like any boost.

## Recommended uses

- Sibilant podcasts and audiobooks (**Sibilance Tamer**).
- Bright or harsh recordings and live streams (**Harshness Control**).
- Dialogue that keeps slipping under the mix (**Speech Presence**).

## Things to avoid

- Maxing **Strength** and **Sensitivity** together — the processing becomes audible (pumping, lisping) on material that didn't need it.
- Treating it as a fix for a consistently dull or bright source — that's a job for static [EQ](help:simple-eq).

## Not a hearing aid

Listening Comfort is a comfort and clarity tool for everyday listening. It is
**not** a hearing aid and not a medical device, and it does not diagnose or
treat any hearing condition. See [Safety & Responsibility](help:safety-limits).

## References

See [References](help:references).
