---
title: "Getting Started"
slug: "getting-started"
category: "Overview"
summary: "Turn on system audio processing, choose an output device, set a safe level, and build your first profile."
keywords:
  - setup
  - first run
  - permissions
  - start
  - quick start
  - onboarding
related:
  - gain-volume
  - profiles
  - output-devices
  - safety-limits
---

# Getting Started

## What SherlockEQ does

SherlockEQ inserts itself between your Mac's audio and your ears. It captures
the system audio mix, runs it through a per-ear equalizer, and plays the
result to your chosen output device. Because it works at the system level,
it affects **every app at once** — music, video, calls, games — with no
per-app setup.

## What it does not do

- It is **not a hearing aid** and **not a medical device**. See [Safety, Limits & Listening Responsibility](help:safety-limits).
- It does not boost what isn't there: EQ reshapes existing sound, it cannot recover detail a recording never captured.
- It does not send your audio or settings anywhere. See [Privacy & Local Data](help:privacy-local-data).

## Step 1 — Grant permissions

On first launch macOS will ask for permission to capture system audio.
SherlockEQ needs two grants:

1. **Microphone** — required by the audio framework even though SherlockEQ does not record you.
2. **System Audio Recording** (called **Screen Recording** on macOS 14) — this is the non-obvious one. Without it, SherlockEQ receives **silence** and the meters stay flat. Grant it in **System Settings → Privacy & Security → Screen & System Audio Recording**, then relaunch.

If audio isn't being processed, this permission is the first thing to check —
see [Troubleshooting](help:troubleshooting).

## Step 2 — Choose your output device

Pick where processed audio should play — built-in speakers, headphones, a USB
DAC, or a Bluetooth device. Changing the output can noticeably change the
perceived EQ, because every device has its own response. See
[Output Devices](help:output-devices).

## Step 3 — Set a safe level

Before boosting anything, set a comfortable baseline. Boosting EQ bands
increases loudness and can cause clipping. As a rule, **cutting is safer than
boosting**. Watch the [VU Meters](help:vu-meters) and read
[Volume / Gain](help:gain-volume) and [Safety](help:safety-limits) before
pushing levels.

## Step 4 — Try Simple EQ

The fastest way to hear what SherlockEQ does: open the Equalizer and use the
[Simple EQ](help:simple-eq) Bass / Mid / Treble controls. Small moves
(±2–4 dB) are usually enough.

## Step 5 — Save a profile

A [profile](help:profiles) stores your EQ, gain, balance, and other settings
together. Make one per listening situation (e.g. "Laptop speakers",
"Headphones — evening"). You can link a profile to a device so it switches
automatically.

## When to use expert features

Reach for the advanced tools when the simple controls aren't enough:

- [Parametric EQ](help:parametric-eq) for precise frequency / gain / Q control.
- [Per-Ear EQ](help:per-ear-eq) and [Audiogram Profiles](help:audiogram-profiles) for asymmetric hearing.
- [Tinnitus Tone Matching](help:tinnitus-tone-matching) to explore a perceived tone.
- [Headphone Correction](help:headphone-correction-autoeq) to flatten a specific headphone.

## Not medical advice

SherlockEQ is not a medical device and does not diagnose or treat any
condition. If you have hearing loss, tinnitus, sudden hearing changes, ear
pain, or dizziness, consult a licensed hearing-care professional or physician.

## References

See the [References](help:references) page for sources cited across the help
system.
