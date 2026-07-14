---
title: "Analog Control Unit"
slug: "analog-control-unit"
category: "Surfaces & Organization"
summary: "A vintage-style control surface that drives a dedicated quick-adjust tone profile plus macOS system volume and output — a separate mode, not a view over your main-window controls."
keywords:
  - analog
  - control unit
  - knobs
  - vintage
  - faceplate
  - panel
related:
  - gain-volume
  - balance
  - graphic-eq
  - vu-meters
---

# Analog Control Unit

## What it does

The Analog Control Unit is an optional, fixed-width window styled like a vintage
hardware front panel, with an expandable spectrum-analyzer panel at the bottom.
It is a **separate quick-adjust mode**: while it's open, audio is routed through
a dedicated, hidden "analog" tone profile, and its Volume and Output knobs reach
out to macOS itself. It does **not** edit — or reflect — your main-window
controls.

## Why it exists

It's a focused, tactile, and frankly fun way to drive the everyday controls
without the full editing window — handy when you just want to nudge tone and
level.

## How the knobs map

- **Volume** → the **macOS system output volume** (via the system, not the app's
  internal [gain](help:gain-volume)). This reaches outside SherlockEQ and changes
  the level of all system audio. The [listening-dose estimate](help:safety-limits)
  tracks this knob: turning it changes your dose accrual rate, just like the
  volume keys.
- **Output** → switches the **macOS default output device**, rerouting all system
  audio (the tap follows it). Not just SherlockEQ's [output](help:output-devices).
- **Balance / Bass / Mid / Treble** → a dedicated **"analog" tone profile** private
  to this window (bass shelf @ 250 Hz, mid bell @ 1 kHz, treble shelf @ 5 kHz, plus
  stereo balance). These do **not** edit your active profile's [Graphic EQ](help:graphic-eq);
  the analog tone is remembered separately across opens.
- **VU meters** → the existing [metering](help:vu-meters).
- **Spectrum panel** → an expandable real-time analyzer with its own display
  settings (color, dimming, sensitivity, peak-only).

## What changes in the audio

While the Analog Control Unit is open, audio is routed through its bare,
dedicated "analog" tone profile — your active profile in the main window is left
untouched and resumes automatically when you close the window. Changes here are
**not** reflected in the main window, and vice versa.

## How it interacts with other settings

- It edits a **private analog tone profile** and the **macOS system volume /
  output device** — it does **not** touch your active [profile](help:profiles) or
  the app's global gain.
- Open it from the **Window** menu (**⌘1**); it coexists with the main window (**⌘0**).

## Recommended uses

- Quick, hands-on tone and level changes.
- A compact "now playing" control surface.

## Things to avoid

- Expecting it to expose advanced features — for [parametric](help:parametric-eq), [audiogram](help:audiogram-profiles), or [tinnitus](help:tinnitus-tone-matching) tools, use the main window.

## Technical notes

The faceplate is a pure SwiftUI view. Its tone knobs drive a hidden per-window
"analog" override profile (a simple Bass/Mid/Treble + balance cascade) that
temporarily replaces the active profile in the audio graph while the window is
open; the Volume and Output knobs call macOS system-volume and default-output
controls directly.

## Limitations

It surfaces only the core controls by design.

## References

See [References](help:references).
