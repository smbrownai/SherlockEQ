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
and no cloud sync.** It does not record your audio and never sends your settings
anywhere. It reaches the internet for exactly two things, neither of which
carries your data: an **optional, on-demand download** of public
headphone-correction curves when you ask for one, and — on standard installs —
a periodic **update check** (see **Network connections** below).

## What SherlockEQ does not collect

- **No telemetry or analytics.** No usage tracking, no crash beacons to us.
- **No account or sign-in.** Nothing to register.
- **No cloud sync** of your settings or profiles unless a future feature explicitly offers it and you turn it on.
- **No audio recording.** SherlockEQ processes the system audio stream in real time to play it back; it does not capture or store it.
- **Your settings never leave your Mac.** The network feature below only *downloads* public correction files; it never uploads anything about you or your configuration.

## Network connections

The [Headphone Correction / AutoEQ](help:headphone-correction-autoeq) browser can
fetch correction curves from the public **AutoEQ** catalog. When (and only when)
you open that browser or pick a headphone:

- SherlockEQ requests the catalog index and the curve you chose from
  `raw.githubusercontent.com` over HTTPS.
- The request carries no account, token, identifier, or information about you —
  it's an anonymous download of a public file, the same as opening the page in a
  browser. Your IP address is visible to GitHub, as with any web request.
- Downloaded curves are cached locally so the app doesn't refetch them. You can
  also import a correction file by hand and never touch the network at all.

**Update checks.** If you installed SherlockEQ from the downloaded disk image,
the app periodically asks `snxt.ai` whether a newer version exists (via the
open-source Sparkle framework). That request is an anonymous fetch of a public
file — it carries your app version so the answer can be computed, and no
system profile, identifier, or settings. Homebrew installs update through
`brew` instead and never make this check; running from Xcode makes none
either. You can also check manually from the app menu at any time.

Beyond those two — the AutoEQ browser you invoke and the update check on
standard installs — SherlockEQ makes no network connections.

## What it stores, and where

- **Profiles** — your EQ, balance, notch, and correction settings — as JSON files in `~/Library/Application Support/SherlockEQ/profiles/`.
- **Preferences** — UI and app settings in standard macOS user defaults.
- **Headphone correction files** you import are read from the location you choose.
- **Downloaded AutoEQ curves** are cached under `~/Library/Application Support/SherlockEQ/autoeq_profiles/` so they aren't refetched. These are public correction files, not personal data.

All of this lives in your user account on your machine, in folders readable only
by your account.

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

SherlockEQ requests **System Audio Recording** permission (shown under
**Screen & System Audio Recording** in System Settings). It does **not** request
microphone access. This permission is required by macOS to capture the system
audio mix for processing — **not** to record you. See
[Getting Started](help:getting-started) and [Troubleshooting](help:troubleshooting).

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
