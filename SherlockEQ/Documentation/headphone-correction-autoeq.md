---
title: "Headphone Correction / AutoEQ"
slug: "headphone-correction-autoeq"
category: "Hearing-Aware Features"
summary: "Flatten a headphone's measured frequency response using AutoEQ-style correction, and where it fits in the chain."
keywords:
  - headphone
  - autoeq
  - correction
  - target curve
  - measurement
  - preamp
related:
  - parametric-eq
  - per-ear-eq
  - audiogram-profiles
  - output-devices
---

# Headphone Correction / AutoEQ

## What it does

Headphone correction applies an EQ that pushes a specific headphone's measured
frequency response toward a chosen **target curve**, so the headphone sounds
closer to a neutral or preferred reference. SherlockEQ reads correction in the
widely used **AutoEQ** text format.

## Why it exists

Every headphone has its own response — some are bass-heavy, some bright, some
uneven in the mids. Correction levels the playing field, letting your other
adjustments (profile, audiogram shaping) start from a more neutral base.

## How to use it

There are two ways to get a correction onto a profile.

**Browse the built-in catalog (online):**

1. Open the headphone-correction section of the profile and search the built-in **AutoEQ catalog** for your model.
2. Pick a result — SherlockEQ downloads that curve from the public AutoEQ project and applies it.
3. Your choice is saved to the profile and the curve is cached locally, so it's offline from then on.

This is the easy path: it fetches public correction files on demand. It's the
only feature that uses the network, it sends nothing about you, and it's
described in [Privacy & Local Data](help:privacy-local-data). If you'd rather not
go online, use the manual path below.

**Import a file by hand (offline):**

1. Obtain an AutoEQ-style correction file for your headphone model (a preamp value plus a list of filters).
2. Import it in the headphone-correction section of the profile.
3. SherlockEQ applies the preamp and filters ahead of your profile EQ.

Either way, SherlockEQ applies the preamp and filters ahead of your profile EQ.

## What changes in the audio

The correction is a set of biquad bands plus a **preamp** (a negative gain that
leaves headroom for the boosts in the correction). It runs **upstream** of your
profile EQ in each ear's chain.

## Why headphones measure differently

- **Model differences:** drivers and tuning vary by design.
- **Fit and seal:** especially for in-ears, seal dramatically changes bass.
- **Ear shape and placement:** your ears aren't the measurement rig's.
- **Measurement rig and target:** corrections are derived on a specific coupler against a specific target curve; a different rig or target yields a different correction.[^1]

So a correction is a **good starting point**, not a guarantee — your ears are
the final judge.

## How it interacts with other settings

- **Order of operations:** correction first (flatten the headphone), then your [profile](help:profiles) EQ and any [audiogram](help:audiogram-profiles) shaping on top.
- Works per ear alongside [Per-Ear EQ](help:per-ear-eq).
- The preamp interacts with master [gain](help:gain-volume); large correction boosts cost headroom.
- Correction is tied to a headphone, so pair it with the right [output device](help:output-devices)/profile.
- SherlockEQ remembers which output device a correction was set up on. If you're later listening on a **different device** — especially the built-in speakers, where a headphone curve is always wrong — a warning appears in the menu-bar popover and on the Equalizer screen, with one-click **Bypass here** and **Dismiss** options. Dismissals are remembered per profile and device.

## Recommended uses

- Neutralizing a known headphone before further personalization.
- A consistent baseline across different headphones (one profile each).

## Things to avoid

- Using a correction made for a different model or target and assuming it fits.
- Removing the preamp — without it, the correction's boosts can clip.
- Stacking heavy correction *and* heavy profile boosts.

## Technical notes

SherlockEQ parses the standard AutoEQ `Preamp: -X dB` line and
`Filter N: ON PK Fc <f> Hz Gain <g> dB Q <q>` entries (peaking and shelf
types), building per-ear biquad bands from them.[^2]

## Limitations

Correction targets an *average* of many ears against a chosen target; it can't
account for your individual fit and anatomy, which is why personal taste still
matters.

## Research context

Headphone target curves and the variability of headphone measurements are an
active area of audio research; widely referenced work includes Harman target
research and the openly documented AutoEq project methodology.[^1][^2]

## References

[^1]: Olive, S., Welti, T., McMullin, E. "Listener Preferences for In-Room and Headphone Target Responses." Audio Engineering Society Conventions, 2013–2017. https://www.aes.org/

[^2]: Pasanen, Jaakko. "AutoEq." Project documentation. https://github.com/jaakkopasanen/AutoEq
