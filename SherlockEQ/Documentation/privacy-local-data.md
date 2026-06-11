---
title: "Privacy & Local Data"
slug: "privacy-local-data"
category: "Responsibility & Data"
summary: "What SherlockEQ stores on your Mac, what it exports, and what it never collects."
keywords:
  - privacy
  - data
  - local
  - telemetry
  - storage
  - export
  - tracking
related:
  - profiles
  - audiogram-profiles
  - getting-started
  - troubleshooting
---

# Privacy & Local Data

## The short version

SherlockEQ keeps your data **on your Mac**. There is **no telemetry, no account,
and no cloud sync.** It does not record your audio and does not phone home with
your settings.

## What SherlockEQ does not collect

- **No telemetry or analytics.** No usage tracking, no crash beacons to us.
- **No account or sign-in.** Nothing to register.
- **No cloud sync** of your settings or profiles unless a future feature explicitly offers it and you turn it on.
- **No audio recording.** SherlockEQ processes the system audio stream in real time to play it back; it does not capture or store it.

## What it stores, and where

- **Profiles** — your EQ, balance, notch, and correction settings — as JSON files in `~/Library/Application Support/SherlockEQ/profiles/`.
- **Preferences** — UI and app settings in standard macOS user defaults.
- **Headphone correction files** you import are read from the location you choose.

All of this lives in your user account on your machine.

## What is exported when you export settings

When you **export** a [profile](help:profiles), SherlockEQ writes that profile's
JSON to a file you pick. That file contains the profile's settings — which may
include **audiogram-derived EQ and a tinnitus notch frequency**. You control
where it goes and who you share it with.

## Why hearing-related settings may be sensitive

An audiogram-shaped profile or a tinnitus notch can imply something about your
hearing. That's **personal information.** SherlockEQ never transmits it, but if
you export or share a profile, treat it as you would any personal data.

## Permissions, and why

SherlockEQ requests **microphone** and **system-audio / screen recording**
permission. These are required by macOS to capture the system audio mix for
processing — **not** to record you. See [Getting Started](help:getting-started)
and [Troubleshooting](help:troubleshooting).

## Recommended uses

- Back up your profiles by exporting them somewhere you trust.
- Review a profile's contents before sharing it.

## Things to avoid

- Posting an exported hearing profile publicly if you consider your hearing data private.

## Limitations

This page describes SherlockEQ's own behavior. Your operating system, backup
software, and any cloud drive you place files in have their own data handling.

## References

See [References](help:references).
