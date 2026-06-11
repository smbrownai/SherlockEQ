---
title: "VU Meters & Visualization"
slug: "vu-meters"
category: "Metering & Visualization"
summary: "What VU meters show, how they differ from peak meters, and how to use them when setting EQ and gain."
keywords:
  - vu
  - meter
  - level
  - peak
  - rms
  - ballistics
  - clipping
related:
  - spectrum-visualization
  - gain-volume
  - safety-limits
  - understanding-eq
---

# VU Meters & Visualization

## What it does

The VU (Volume Unit) meters show the **average level** of the audio over a
short window, with the smooth, weighted motion of a classic analog meter. They
give you an at-a-glance sense of how loud the signal *feels*.

## Why it exists

Numbers alone don't convey loudness well. A meter that responds the way
perceived loudness does helps you set [gain](help:gain-volume) and EQ to a
consistent level and notice when you're pushing too hard.

## How to use it

- Watch the meters while adjusting EQ — boosts will push them up.
- Aim for a comfortable, consistent average rather than chasing the top.
- If the meters sit near the top constantly, reduce gain or EQ boosts.

## What they show — and what they don't

- A VU meter reflects **average** level with deliberate **ballistics** (a defined rise/fall time), historically ~300 ms to reach reference.[^1] It is **not** a peak meter.
- Because it averages, **brief peaks can still clip** even when the VU reads modest. SherlockEQ also provides a **dBFS reference scale** and a peak-aware safety view so you can catch transients the VU smooths over.
- The meter shows **digital level (dBFS)**, not calibrated loudness in your room. It is not a sound-level meter — see [Safety](help:safety-limits).

## How it differs from peak meters

A **peak** meter catches the highest instantaneous sample (what matters for
clipping); a **VU/average** meter tracks sustained energy (what correlates with
perceived loudness). They answer different questions, which is why both are
useful.

## How it interacts with other settings

- Reflects the processed signal *after* EQ, [balance](help:balance), and [gain](help:gain-volume).
- The [spectrum view](help:spectrum-visualization) breaks the same signal down by frequency.
- Zone colors align with the safe-listening thresholds, so the meters and the [safety](help:safety-limits) view agree at a glance.

## Recommended uses

- Gain-staging after EQ changes.
- Spotting a left/right level imbalance.

## Things to avoid

- Treating a mid-scale VU reading as "no clipping" — check the peak/safety indicators too.
- Reading the meter as a calibrated SPL measurement.

## Technical notes

SherlockEQ's analog VU uses a critically damped second-order integrator tuned
to the standard ~300 ms rise time, computed from RMS level, so its motion
matches the IEC characteristic.[^1]

## Research context

VU and peak-programme metering ballistics are defined by international
standards (IEC 60268-17 for the VU meter; IEC 60268-18 for PPM), which specify
the response times that make a meter's motion meaningful.[^1]

## References

[^1]: International Electrotechnical Commission. IEC 60268-17, *Sound system equipment – Part 17: Standard volume indicators*. https://www.iec.ch/
