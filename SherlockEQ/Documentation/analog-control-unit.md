---
title: "Analog Control Unit"
slug: "analog-control-unit"
category: "Surfaces & Organization"
summary: "A vintage-style control surface that maps directly onto SherlockEQ's existing controls — not a separate processing mode."
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
  - simple-eq
  - vu-meters
---

# Analog Control Unit

## What it does

The Analog Control Unit is an optional, fixed-size window styled like a vintage
hardware front panel. Its knobs and meters are a **direct view over controls you
already have** — turning a knob here is exactly the same as moving the
corresponding slider elsewhere.

## Why it exists

It's a focused, tactile, and frankly fun way to drive the everyday controls
without the full editing window — handy when you just want to nudge tone and
level.

## How the knobs map

- **Volume** → master [gain](help:gain-volume).
- **Balance** → [balance](help:balance).
- **Bass / Mid / Treble** → [Simple EQ](help:simple-eq).
- **VU meters** → the existing [metering](help:vu-meters).
- **Output selector** (if shown) → the active [output device](help:output-devices).

## What changes in the audio

Nothing new. The Analog Control Unit is **not a separate processing mode** — it
writes to the same state as the main window and popover. Whatever you set here
is reflected everywhere, and vice versa.

## How it interacts with other settings

- It edits the **active [profile](help:profiles)** and global gain, just like the other surfaces.
- Open it from the **Window** menu; it coexists with the main window.

## Recommended uses

- Quick, hands-on tone and level changes.
- A compact "now playing" control surface.

## Things to avoid

- Expecting it to expose advanced features — for [parametric](help:parametric-eq), [audiogram](help:audiogram-profiles), or [tinnitus](help:tinnitus-tone-matching) tools, use the main window.

## Technical notes

The faceplate is a pure SwiftUI view bound to the same observable state objects
as the rest of the app; there is no additional audio processing behind it.

## Limitations

It surfaces only the core controls by design.

## References

See [References](help:references).
