---
title: "Safety, Limits & Listening Responsibility"
slug: "safety-limits"
category: "Responsibility & Data"
summary: "Why EQ changes loudness, how to avoid clipping and fatigue, and how to listen responsibly."
keywords:
  - safety
  - loudness
  - clipping
  - fatigue
  - dose
  - niosh
  - hearing protection
related:
  - gain-volume
  - vu-meters
  - tinnitus-tone-matching
  - audiogram-profiles
---

# Safety, Limits & Listening Responsibility

## The short version

**If listening is uncomfortable, stop or turn it down.** Discomfort is a signal
to respect, not push through. EQ can make audio louder than it looks, boosts can
distort, and prolonged loud listening can harm hearing. SherlockEQ gives you
metering and a listening-dose estimate to help, but **you** set the levels.

## Why EQ can increase perceived loudness

Every boost adds energy. Lifting bass, presence, or treble raises the overall
level and can make a track noticeably louder even if you didn't touch the volume.
Several boosts **stack**. After boosting, check the [VU meters](help:vu-meters)
and consider lowering [gain](help:gain-volume).

## Why boosts can cause clipping

Digital audio has a hard ceiling (0 dBFS). Boosts plus make-up gain can push
peaks past it, and the signal **clips** — flattens into harsh distortion.
**Cutting is safer than boosting:** cut problem areas and add modest make-up gain
to keep headroom.

## Why high-frequency boosts can be fatiguing

The ear is sensitive in the presence/treble region, so even small boosts there
can feel sharp or tiring over time. Use gentle moves and take breaks.

## Tinnitus and tone sweeps

If you use [Tinnitus Tone Matching](help:tinnitus-tone-matching), keep the level
**low**. Loud sustained tones are uncomfortable and unnecessary for comparison.
Stop if anything is uncomfortable.

## Listening dose

SherlockEQ estimates a daily listening **dose** using the NIOSH recommended
exposure model — 85 dBA over 8 hours with a 3 dB exchange rate — and tints its
indicators as you approach the limit.[^1] The estimate is anchored to the
system volume you calibrate at: when you later turn the volume up or down (or
mute), SherlockEQ tracks that change into the estimate automatically, as long
as your output device exposes its volume (most do; some HDMI and optical
devices don't — the Safe Listening screen tells you which case applies). This
is still an **informational estimate**, not a calibrated measurement: it
depends on a playback-level calibration you provide and on assumptions about
your device and headphone fit, so treat it as guidance, not a certified
exposure reading.

## What SherlockEQ is not

SherlockEQ is **not** a calibrated sound-level meter, dosimeter, or
occupational-exposure monitor. Its on-screen levels are **dBFS** (digital full
scale), not SPL in your room. For workplace noise compliance or a clinical
measurement, use certified equipment and professionals.

## A responsible-listening statement

Protect your hearing. Keep levels comfortable, take regular breaks, and be
especially cautious with headphones and with sustained loud content. Noise-
induced hearing loss is **cumulative and permanent**, and it is preventable by
limiting both level and duration.[^1][^2] If you notice ringing, muffling, pain,
or fullness after listening, lower your levels and rest your ears — and seek
care if symptoms persist.

## Not medical advice

SherlockEQ is **not a medical device**. It does not diagnose, treat, cure, or
prevent hearing loss, tinnitus, or any condition. If you have hearing loss,
tinnitus, sudden hearing change, ear pain, or dizziness, consult a licensed
hearing-care professional or physician.

## References

[^1]: U.S. National Institute for Occupational Safety and Health (NIOSH). *Criteria for a Recommended Standard: Occupational Noise Exposure*, DHHS (NIOSH) Publication No. 98-126, 1998. https://www.cdc.gov/niosh/docs/98-126/

[^2]: World Health Organization. "Deafness and hearing loss" (fact sheet), 2024. https://www.who.int/news-room/fact-sheets/detail/deafness-and-hearing-loss
