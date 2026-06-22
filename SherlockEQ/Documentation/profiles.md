---
title: "Profiles"
slug: "profiles"
category: "Surfaces & Organization"
summary: "What a profile stores, how switching works, and how profiles relate to devices and headphones."
keywords:
  - profile
  - preset
  - save
  - switch
  - export
  - import
  - backup
related:
  - output-devices
  - getting-started
  - privacy-local-data
  - per-ear-eq
---

# Profiles

## What it does

A profile bundles a complete setup — EQ bands (per ear), EQ mode,
[balance](help:balance), [tinnitus notch](help:tinnitus-tone-matching),
[headphone correction](help:headphone-correction-autoeq), and device link —
under one name. Switching profiles swaps all of it at once. (Master
[gain](help:gain-volume) is a global output trim.)

## Why it exists

You listen in different situations — laptop speakers, headphones at night, a
desk DAC. Profiles let you save the right setup for each and recall it
instantly.

## How to use it

- Create a profile per situation and give it a clear name.
- Edit its EQ and settings in the main window.
- Link it to an [output device](help:output-devices) for automatic switching.
- **Export / Import** a profile as a file to back it up or move it to another Mac.

## What changes in the audio

Activating a profile applies its entire EQ and correction chain per ear. The
change is immediate.

## How it interacts with other settings

- Choosing a profile sets the EQ, balance, notch, and correction in effect.
- **Factory presets are editable in place.** SherlockEQ ships four — **Voice Clarity**, **Music Balanced**, **Gentle Listening**, and **Presence Boost** (a fresh install starts on Music Balanced). Editing one saves your changes to it; there's no need to duplicate first. Use **Reset to Factory Default** on a preset to return it to its shipped values, or **Restore Factory Presets** to bring back any you deleted.
- Want to keep a factory preset untouched? **Duplicate** it and edit the copy.
- Device-linked profiles can switch automatically when you plug in or connect a device.

## Recommended example profiles

- **Laptop speakers** — gentle bass/treble lift, conservative level.
- **Headphones — evening** — correction on, lower overall level.
- **Speech / calls** — midrange presence for clarity.

## Things to avoid

- One mega-profile for everything — per-situation profiles work better.
- Editing a factory preset and forgetting it — if you want the original back, use **Reset to Factory Default**.

## Technical notes

Profiles are stored as individual JSON files in
`~/Library/Application Support/SherlockEQ/profiles/`. Export writes that JSON;
import copies it in as a new, user-owned profile.

## Limitations

A profile captures SherlockEQ's settings, not your device's own controls or OS
audio settings.

## Privacy

Profiles can include hearing-related settings (audiogram-derived EQ, tinnitus
notch), which may be **sensitive**. They stay on your Mac. See
[Privacy & Local Data](help:privacy-local-data).

## References

See [References](help:references).
