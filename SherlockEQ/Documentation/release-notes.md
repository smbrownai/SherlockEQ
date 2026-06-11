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
