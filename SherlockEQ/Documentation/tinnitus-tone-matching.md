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

The screen is a short four-step flow:

1. **Set a comfortable tone level** — press Play and set a quiet level; you'll match pitch first, loudness doesn't matter. A prominent **Stop** is available while the tone plays.
2. **Sweep for the closest pitch** — drag across the range; pause where a tone matches. Use the **Step** selector (1 / 10 / 100 Hz) with **−** / **+** to fine-tune.
3. **Compare slightly higher and lower** — nudge a little each way, and check an **octave** down/up (a common source of confusion).
4. **Use this pitch** — places the notch at the current tone and turns it on. A Left / Right / Both choice appears only when **Separate L+R notch** is enabled (see [Per-Ear EQ](help:per-ear-eq)).

Keep the level low. The goal is comparison, not loudness.

### Guided matching (optional)

Because pitch matching is imprecise and easy to get an octave wrong, step 3
includes an optional **Average a few matches** aid: **capture** the same match
a few times and it shows a suggested **average** and **range** — a more honest
figure than a single "definitive" number — which you can move the tone to
before using it.

### Strength presets

The notch has three comfort presets that trade fidelity for reduction:

- **Subtle** — narrow, shallow: keeps audio clearest.
- **Balanced** — a noticeable softening while preserving most detail.
- **Strong** — a wider, deeper cut that may sound duller or muffled.

Start with **Subtle** or **Balanced**. The **Depth** and **Width** sliders
(behind **Fine-tune notch**) remain available if you want manual control; the
preview above the controls shows the exact band being reduced. When the notch
is off, the section collapses to a short preview and an **Enable** button at
the pitch you found.

### Check-in

An optional daily **check-in** — opened from its own button at the bottom of
the screen, since it tracks rather than configures — lets you rate how much the
ringing bothered you (0–10) and see a trend over time. It is **not** a clinical score — it just helps
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

- If your [audiogram](help:audiogram-profiles) correction **boosts** the same frequency your notch **cuts**, a warning explains the collision — a narrower notch keeps more of the correction, a shallower notch keeps more relief. Common with high-frequency hearing loss, where tinnitus usually sits in the region of maximum loss.

- A notch is a dedicated per-profile control, shown only as a marker on the [Parametric EQ](help:parametric-eq) curve. You adjust or remove it on the Tinnitus Notch screen, not as an ordinary EQ band.
- With [Per-Ear EQ](help:per-ear-eq), you can notch one ear independently.
- The reference tone ignores your profile EQ so the pitch you hear isn't colored by it.

## Limitations of self-directed tone matching

- **Tinnitus is not always tonal.** It can be **broadband** (hiss, noise), **multiple tones**, **pulsatile**, or have **no clear match** at all.[^1]
- It often **fluctuates** day to day, so a match today may not hold tomorrow.[^2]
- Self-matching is approximate and prone to **octave confusion** (matching a tone one octave off).[^2]

## When a notch may help

A notch is **best for** steady, tone-like ringing at a pitch you can find again.
It is **less suited** to hissing, roaring, clicking, pulsing, or tinnitus that
changes pitch often. The notch simply reduces audio energy around the pitch you
selected — a way to explore whether listening feels less fatiguing. It is **not
a treatment** and does not remove tinnitus; evidence for notched-sound
approaches is mixed, and hearing-aid evaluation or CBT have stronger support for
persistent, bothersome tinnitus.

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
