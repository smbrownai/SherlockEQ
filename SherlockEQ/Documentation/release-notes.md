---
title: "Release Notes"
slug: "release-notes"
category: "Reference"
summary: "What changed in this version of SherlockEQ, and where to find the full history."
keywords:
  - release notes
  - changelog
  - version
  - updates
  - whats new
related:
  - feature-guide
  - getting-started
  - troubleshooting
---

# Release Notes

The version this documentation corresponds to is shown at the bottom of the
help sidebar. Use **SherlockEQ → Check for Updates…** to get the latest build.

## 0.3.1

A focused follow-up to 0.3.0. The Analog Control Unit's OUTPUT row now actually switches your Mac's audio output instead of just labelling it, its COLOR control matches the panel's other switches, and you can quit SherlockEQ straight from the menu-bar popover.

**Added**

- **Switch audio output from the Analog Control Unit.** The OUTPUT buttons now scan for your Mac's available output devices and let you switch between them — built-in speakers, headphones, an external DAC — right from the panel. It sets the system output (the same selection as the menu-bar sound control), and SherlockEQ follows the new device automatically. The lit button is the current output.
- **Quit from the menu bar.** A *Quit SherlockEQ* option now sits at the bottom of the menu-bar popover, so you can quit without opening the main window or hunting through the app menu.

**Changed**

- **The spectrum analyzer's COLOR control is now a normal switch.** It no longer paints the palette onto the switch itself — off is green, on is the colourful palette, matching the PEAK switch beside it.

## 0.3.0

A big optional addition plus a round of polish. The headline is the **Analog Control Unit** — a vintage hi-fi front panel you can leave open on the desktop for the five adjustments people understand immediately: volume, balance, bass, mid, and treble. There's also a new in-app Help system, a quick Listening Comfort toggle in the menu bar, and a more readable accent colour in light mode.

**Added**

- **Analog Control Unit.** Open it from *Window → Analog Control Unit*: warm stereo VU meters, a system-volume knob, balance, and a simple bass / mid / treble tone on a dark brushed-metal faceplate. It runs on its own isolated profile, so casual knob-twiddling never touches your carefully tuned EQ. The VOLUME knob drives the macOS output level directly; balance and tone map to SherlockEQ's simple EQ.
- **Built-in spectrum analyzer.** Click the chevron at the bottom of the Analog Control Unit to slide out a classic rack spectrum analyzer — 31 third-octave bars with a frequency label under each. Switch between a green and a colourful palette, dim the display, dial in sensitivity, and flip between full bars and a moving peak tick.
- **In-app Help.** A proper Help menu and contextual *?* buttons throughout the app open a searchable help window covering every feature — what it does, how to use it, and the safety boundaries.
- **Listening Comfort toggle in the menu bar.** Turn the comfort processors on or off from the menu-bar popover without opening the full window — right next to the Tinnitus Notch toggle.

**Changed**

- **Accent colour reads better in light mode.** The gold accent is now appearance-aware — a deeper gold on light backgrounds so sliders, toggles, and the active sidebar item meet contrast guidelines, with the brighter gold kept for dark mode.
- **Equalizer moved to the top of the sidebar.** Audio Processing now lists Equalizer first, then Audiogram, Tinnitus Notch, Listening Comfort, and Safe Listening.
- **Expert EQ shows the spectrum only.** The Spectrum / Bars switch is hidden for now; the Expert canvas always shows the live spectrum behind your curve. Bars will return.

**Fixed**

- **The updater shows real release notes again.** "Check for Updates" now renders these formatted notes in the update window instead of loading the GitHub release web page.

## 0.2.0 — Listening Comfort

The first feature release since 0.1: **Listening Comfort** — level-dependent
processing that shapes sound only while it needs it, instead of permanently
re-tuning the curve. Soften a harsh "sss," ease shouty midrange, or lift
dialogue over a score — each engages when the triggering sound is present and
relaxes when it's gone. Per ear, zero added latency, with the peak limiter as
the ceiling over any boost.

**Added**

- **Listening Comfort panel** — three named processors (Speech Presence, Harshness Control, Sibilance Tamer), each an on/off plus Strength and Sensitivity sliders with a live activity meter. Independent per ear.
- **Adaptive, level-independent triggering** — each processor reacts relative to a slow rolling average of its target band, so it behaves the same on a quiet podcast and a loud movie, no SPL calibration required.
- **Dynamics overlay on the Expert canvas** — a Dynamics layer chip draws each active processor's response live against the spectrum.

**Changed**

- **Reference Mode and chain bypass now cover the comfort tools** — ⌘B drops the comfort stage with the rest of the chain for a true A/B; a per-stage toggle disables comfort while keeping EQ, correction, and notch active.

**Fixed**

- The menu-bar popover no longer lingers in front of the main window after opening the full app.

**Not a medical device** — SherlockEQ does not diagnose, treat, measure, or
monitor any hearing condition or tinnitus. The Listening Comfort tools shape
audio for comfort and clarity; they are not a hearing aid. See
[Safety, Limits & Listening Responsibility](help:safety-limits).

## Earlier versions

Full release notes for every version are published with each release. See
**Check for Updates…** in the app menu, or the project's releases page online.
