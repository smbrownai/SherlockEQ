---
title: "Tinnitus Tone Matching"
slug: "tinnitus-tone-matching"
category: "Hearing-Aware Features"
summary: "Explore an approximate perceived tinnitus tone with a sweep and set a notch — without making treatment claims."
keywords:
  - tinnitus
  - ringing
  - tone
  - notch
  - sweep
  - pitch match
related:
  - parametric-eq
  - safety-limits
  - per-ear-eq
  - references
---

# Tinnitus Tone Matching

## What it does

The Tone Finder plays a clean, continuous sine tone you can sweep up and down in
frequency. If your tinnitus is **tonal**, you can use it to find a frequency
that approximates your perceived pitch, then optionally set a **notch** filter
(a narrow cut) at that frequency in your EQ.

## Why it exists

Many people with tinnitus are curious where their tone sits and want to explore
it interactively. The Tone Finder gives a controlled, repeatable way to do that
on your own terms.

## How to use it

1. Start the sweep at a comfortable, low level.
2. Move slowly across the range; pause where a tone seems to match your tinnitus.
3. Fine-tune around that frequency.
4. Optionally **Set as Notch** to place a gentle cut there. This sets both ears; a Left / Right / Both choice appears only when **Separate L+R notch** is enabled (see [Per-Ear EQ](help:per-ear-eq)).

Keep the level low. The goal is comparison, not loudness.

### Guided matching (optional)

Because pitch matching is imprecise and easy to get an octave wrong, the
**Guided matching** panel walks through a short protocol: sweep up from below,
compare a tone an **octave** down and up (a common source of confusion), then
**capture** the same match a few times. Once you've captured two or more, it
shows a suggested **average** and the **range** — a more honest figure than a
single "definitive" number. You can set the notch straight from that average.

### Strength presets

The notch has three comfort presets that trade fidelity for reduction:

- **Subtle** — narrow, shallow: keeps audio clearest.
- **Balanced** — a noticeable softening while preserving most detail.
- **Strong** — a wider, deeper cut that may sound duller or muffled.

Start with **Subtle** or **Balanced**. The **Depth** and **Width** sliders
(behind *Fine-tune*) remain available if you want manual control; the preview
above the controls shows the exact band being reduced.

### Check-in

An optional daily **check-in** lets you rate how much the ringing bothered you
(0–10) and see a trend over time. It is **not** a clinical score — it just helps
you notice whether things trend better rather than chasing the ringing day to
day. Loudness and annoyance are deliberately separated: annoyance is what
sound-therapy and habituation approaches aim to reduce.

## What you'll hear

A notch usually sounds slightly **less bright or less sharp** around the
selected pitch — not a disappearance of the tinnitus. A narrow, shallow notch
stays clear; a wider or deeper one can sound dull, hollow, or muffled,
especially on speech (the 3–6 kHz region carries consonant clarity). You are
hearing ordinary audio with one region de-emphasized, nothing more.

## What changes in the audio

The Tone Finder generates a reference sine that bypasses your EQ, so it's a
clean comparison tone. Setting a notch adds a **finite, depth-controlled dip**
to your per-ear EQ chain — it does not change the tone generator.

## How it interacts with other settings

- A notch is a dedicated per-profile control, shown only as a marker on the [Parametric EQ](help:parametric-eq) curve. You adjust or remove it on the Tinnitus Notch screen, not as an ordinary EQ band.
- With [Per-Ear EQ](help:per-ear-eq), you can notch one ear independently.
- The reference tone ignores your profile EQ so the pitch you hear isn't colored by it.

## Limitations of self-directed tone matching

- **Tinnitus is not always tonal.** It can be **broadband** (hiss, noise), **multiple tones**, **pulsatile**, or have **no clear match** at all.[^1]
- It often **fluctuates** day to day, so a match today may not hold tomorrow.[^2]
- Self-matching is approximate and prone to **octave confusion** (matching a tone one octave off).[^2]

## Recommended uses

- Personal exploration of an approximate perceived pitch.
- Creating a subtle notch in your listening profile if you find it comfortable.

## Things to avoid

- High playback levels during sweeps — keep it quiet and stop if uncomfortable.
- Expecting the notch to reduce or treat your tinnitus (see below).
- Long, repeated loud exposure while searching.

## Technical notes

The generator is a continuous-phase sine to avoid clicks while sweeping. The
notch is realized as a **parametric (peaking) biquad with negative gain** from
the same EQ engine as the rest of the app — a finite dip whose **depth** (in dB)
and **width** (Q → octave bandwidth) are exactly what the preview draws, so what
you see matches what you hear. Narrow ≈ Q 8 (~0.18 octave), Medium ≈ Q 4
(~0.36 octave), Wide ≈ Q 2 (~0.72 octave).

## Research context

Tinnitus pitch- and loudness-matching are established **psychoacoustic
measurement** techniques, but they are characterizations, not treatments, and
have known reliability limits including octave confusion.[^2] **Notched-sound**
and **sound-therapy** approaches have been studied with **mixed and
inconclusive** results, and major clinical guidelines do **not** establish that
notch filtering reduces tinnitus; recommended, evidence-supported management
centers on education and **cognitive behavioral therapy** for tinnitus-related
distress.[^1][^3] SherlockEQ makes **no treatment claim**: the Tone Finder is an
exploration tool only.

## Limitations

SherlockEQ cannot measure your tinnitus, cannot verify a match, and is not a
therapy device. Results vary and may not match at all.

## Not medical advice

SherlockEQ is **not a medical device** and does **not** diagnose, treat, cure,
or prevent tinnitus. Notch filtering is **not** a proven tinnitus treatment. If
you have tinnitus — especially new, one-sided, pulsatile, or with hearing loss,
ear pain, or dizziness — consult a licensed hearing-care professional or
physician.

## References

[^1]: Tunkel, D. E., et al. "Clinical Practice Guideline: Tinnitus." *Otolaryngology–Head and Neck Surgery*, 151(2 Suppl), 2014. https://doi.org/10.1177/0194599814545325

[^2]: Henry, J. A., et al. "Measurement of tinnitus." *Otology & Neurotology* / *Journal of the American Academy of Audiology* reviews on pitch and loudness matching reliability. https://doi.org/10.3766/jaaa

[^3]: Cima, R. F. F., et al. "A multidisciplinary European guideline for tinnitus: diagnostics, assessment, and treatment." *HNO*, 2019. https://doi.org/10.1007/s00106-019-0633-7
