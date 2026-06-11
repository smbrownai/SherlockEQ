---
title: "Output Devices"
slug: "output-devices"
category: "Surfaces & Organization"
summary: "How SherlockEQ plays to speakers, headphones, USB DACs, and Bluetooth — and why output changes alter perceived EQ."
keywords:
  - output
  - device
  - speakers
  - headphones
  - usb dac
  - bluetooth
  - airpods
  - latency
related:
  - profiles
  - balance
  - headphone-correction-autoeq
  - troubleshooting
---

# Output Devices

## What it does

SherlockEQ plays its processed audio to an output device you choose: built-in
speakers, wired headphones, external speakers, a USB DAC, or a Bluetooth /
wireless device. It can switch the active [profile](help:profiles) automatically
when the device changes.

## Why it exists

Different devices need different settings. Picking the output explicitly — and
linking a profile to it — means your correction follows the hardware.

## How to use it

Choose the output in the profile's device row. Link a profile to a device's
identifier so SherlockEQ activates it automatically when that device appears.

## Device-specific notes

- **Built-in speakers:** small drivers; gentle bass and treble shaping usually helps more than large boosts.
- **Wired headphones / IEMs:** each driver sits at one ear, so [Per-Ear EQ](help:per-ear-eq) and [headphone correction](help:headphone-correction-autoeq) are most precise here.
- **External speakers / USB DACs:** typically the cleanest, lowest-latency path; sample rate can differ from the source.
- **Bluetooth / AirPods / wireless:** convenient, but add noticeable **latency** (audio lags video/typing), use their own internal processing, and may renegotiate format. Expect a less tight feel than wired.

## What changes in the audio

The output device is the last link before your ears. Its own frequency
response, channel handling, and any internal DSP shape what you actually hear —
so the **same EQ sounds different on different devices**.

## How it interacts with other settings

- A [profile](help:profiles) can be tied to a device for auto-switching.
- [Balance](help:balance) and [per-ear](help:per-ear-eq) behavior differ between speakers (acoustic crosstalk) and headphones (channel isolation).
- Sample-rate handling is automatic; a mismatch is surfaced rather than silently mishandled.

## Recommended uses

- One profile per device you use regularly.
- Headphone correction paired with the matching headphone profile.

## Things to avoid

- Expecting identical sound across devices — re-check levels after switching.
- Relying on tight A/V sync over Bluetooth.

## Technical notes

SherlockEQ stamps its processing graph at the output device's sample rate and
re-checks routing on device changes, so switching devices reconfigures the
chain cleanly.

## Limitations

SherlockEQ can't override a device's own internal processing or its physical
response — it can only shape the signal it sends.

## References

See [References](help:references).
