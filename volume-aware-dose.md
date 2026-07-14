# SherlockEQ — Volume-Aware Listening Dose

**Feature:** Anchor the SPL calibration to the hardware output volume it was measured at, and track live volume changes into the dose estimate
**Scope:** `SystemVolumeController` promotion (UI/AnalogUnit → Audio) + dB/mute/UID readout, a pure anchor-math helper, AudioState wiring, Safe Listening UI status, doc sync
**Status:** ✅ Shipped alongside this document
**Spec date:** 2026-07-14

---

## 1. The problem

CATap captures the process mix **upstream of the output device's volume control**.
The dose pipeline converts that signal to dBA as:

```
dBA = dBFS + calibrationOffsetDBA        (constant, default 100, persisted)
```

Because the tap never sees the hardware volume, the estimate is anchored to
whatever volume happened to be set when the user calibrated — and stays there:

- Calibrate at 70 % volume, later listen at 25 % → dose over-counts by the
  attenuation delta (tens of dB); the user gets nagged for exposure they
  aren't receiving.
- Calibrate at 40 %, later crank to 100 % → dose **under-counts** a genuinely
  loud condition. This is the failure mode that matters: "do no harm" is the
  app's first principle, and the safety feature was silently blind to the
  volume knob.

The Safe Listening screen disclosed this ("Actual SPL depends on … system
volume"), but a disclaimer is not a fix.

## 2. The fix, in one line

Record the system output volume (in dB) and the output device's UID at the
moment the user sets the calibration; at runtime, shift the effective
calibration by the live volume delta:

```
effectiveOffset = calibrationOffsetDBA + (currentVolumeDB − anchorVolumeDB)
```

when the current device is the anchor device and its volume is readable;
otherwise fall back to the legacy constant-offset behavior (delta = 0).

## 3. Design notes (read before touching code)

**1. The delta model is exact for the quantity we need.** We never need the
absolute dB mapping of the volume control to be right — only the *difference*
between the calibration-time reading and the live reading, on the same device,
read through the same property path. Any monotone, device-consistent dB
readout gives a correct delta.

**2. The analyzers stay untouched; AudioState pushes an effective offset.**
`SpectrumAnalyzer` already exposes one knob (`calibrationOffsetDBA`) and fires
`onLevelUpdate(dba)` into the tracker. Instead of teaching the analyzer or the
tracker about volume, `AudioState` recomputes
`effective = base + delta` whenever either component changes and pushes it
into both analyzers. Dose feed, current-level readout, meter zone boundaries,
and the canvas safety overlay all inherit the correction from one place.

**3. The easter egg's plumbing becomes load-bearing.** `SystemVolumeController`
(previously private to the Analog Control Unit's VOLUME knob) moves to
`Audio/` and grows a dB readout, mute state, and device UID. The analog unit
keeps its own window-lifecycle instance; `AudioState` owns a second, always-on
instance. Two HAL listeners on the same properties are trivial; sharing one
instance would couple the analog window's start/stop lifecycle to the dose
tracker's. A consequence the user should enjoy: twisting the nostalgic VOLUME
knob now correctly moves the dose accrual rate.

**4. Fallback is always the legacy behavior, never worse.** Every failure to
read (device without a volume property, HDMI/optical, device mismatch after a
route change, legacy install with no recorded anchor) degrades to delta = 0 —
exactly the pre-feature estimate. The feature can only add information.

## 4. Volume readout (`SystemVolumeController`)

New published state, all fed from the existing queue-confined CoreAudio reads
(volume-change listener + default-device retarget — no polling):

| Property | Meaning |
|---|---|
| `volumeDB: Double?` | Current output volume in dB; `nil` when the device exposes no readable volume |
| `isMuted: Bool` | `kAudioDevicePropertyMute` on the output scope (false when the property is absent) |
| `deviceUID: String?` | `kAudioDevicePropertyDeviceUID` of the bound default output device |

dB read strategy, first hit wins (per device, so deltas stay self-consistent):

1. `kAudioDevicePropertyVolumeScalarToDecibels` translation of the current
   virtual-main scalar (element main, then channel 1) — the device's own
   scalar→dB curve, exact.
2. `kAudioDevicePropertyVolumeDecibels` direct read (element main, then
   channel 1).
3. `20·log10(scalar)` floor-clamped — approximate taper, but monotone and
   consistent, which is all the delta needs (Design note 1).

## 5. Anchor math (`CalibrationVolumeAnchor`, pure + unit-tested)

```swift
struct CalibrationVolumeAnchor: Equatable {
    var volumeDB: Double     // reading when the user set the calibration
    var deviceUID: String    // device the calibration was measured on
}
```

`deltaDB(anchor:currentVolumeDB:currentDeviceUID:isMuted:)` rules, in order:

1. **Muted → −120 dB.** Muted output is silence at the ear regardless of
   device identity; NIOSH accumulation at the resulting level is ~0. (The
   spectrum keeps showing signal — it is a signal view; the dose is an
   exposure view.)
2. **No anchor (legacy install, or volume unreadable when calibration was
   set) → 0.**
3. **Current volume unreadable → 0.**
4. **Device UID ≠ anchor UID → 0.** Different device means different
   headphones/speakers — the SPL anchor itself is stale, not just the
   volume. The UI tells the user to recalibrate (§7).
5. Else **clamp(current − anchor, −80 … +40)** — a NaN/absurdity guard, wide
   enough never to bind in real use (under-counting loud conditions is the
   harm being fixed, so the top is generous).

A companion `status(...)` function returns
`muted / active(deltaDB:) / unanchored / unavailable / deviceMismatch` for the
Safe Listening status row, so UI copy and dose math can't disagree.

## 6. AudioState wiring

- Owns `let systemVolume = SystemVolumeController()`, started in `init`,
  never stopped.
- `@Published private(set) var volumeDeltaDB: Double = 0` +
  `var effectiveCalibrationOffsetDBA: Double { calibrationOffsetDBA + volumeDeltaDB }`.
- Controller changes → deferred `Task { @MainActor … refreshVolumeDelta() }`
  (deferred because `@Published` sinks fire in `willSet` — the established
  stale-read rule).
- `refreshVolumeDelta()` recomputes the delta and pushes
  `Float(effective)` into `spectrum` + `preSpectrum` — replacing the two
  direct base-offset pushes.
- **Anchor snapshot:** `calibrationOffsetDBA.didSet` records
  `{systemVolume.volumeDB, systemVolume.deviceUID}` to UserDefaults
  (`sherlockeq.calibrationAnchorVolumeDB` / `…AnchorDeviceUID`) whenever both
  are readable, and clears the anchor otherwise. Every path that sets the
  calibration — slider drag, meter-reading Apply, `resetSettingsToDefaults` —
  re-anchors at the current volume, which is exactly the statement the user
  is making ("at *this* volume, 0 dBFS is X dB SPL").
- UI consumers of the offset for **display of at-ear level** switch to
  `effectiveCalibrationOffsetDBA`: popover level strip, MonitorSidebar VU
  zone boundaries, canvas safety overlay (Expert + Advanced). The Safe
  Listening **calibration slider** keeps binding the base value — it is the
  anchor, not the live estimate.

Threading: `SpectrumAnalyzer.calibrationOffsetDBA` remains a plain `Float`
written from main / read on the audio thread — the same benign pattern as
before, now written on volume changes as well as slider drags (still rare,
still a single aligned Float store).

## 7. Safe Listening UI

Under the Playback-calibration slider, a live status line driven by
`status(...)`:

- **active** — "System volume is tracked: the estimate currently includes
  {+X.X dB} for the volume change since calibration."
- **muted** — "Output is muted — no exposure is accumulating."
- **deviceMismatch** — "Calibrated on a different output device. Recalibrate
  to re-anchor volume tracking."
- **unavailable** — "This output device doesn't expose its volume — the
  estimate assumes the volume from calibration time."
- **unanchored** — "Set the calibration once to anchor it to your current
  volume."

The "About this estimate" disclaimer bullet drops "system volume" from the
list of unmodeled factors and states that volume is tracked when the device
exposes it.

## 8. Files touched

| File | Change |
|---|---|
| `Audio/SystemVolumeController.swift` | moved from `UI/AnalogUnit/`; +`volumeDB`/`isMuted`/`deviceUID` |
| `Audio/VolumeAnchoredCalibration.swift` | NEW — anchor struct + pure delta/status math |
| `State/AudioState.swift` | own controller, delta refresh, anchor snapshot, effective-offset push |
| `UI/Window/SafeListening/SafeListeningView.swift` | status row + disclaimer copy |
| `UI/Popover/MainPopoverView.swift`, `UI/Window/Monitor/MonitorSidebar.swift`, `UI/Window/Equalizer/{Expert,Advanced}EQView.swift` | pass `effectiveCalibrationOffsetDBA` |
| `SherlockEQTests/VolumeAnchoredCalibrationTests.swift` | NEW — §9 |
| `sherlockEQ-spec.md` §5.4/§7.5, `Documentation/safety-limits.md`, `Documentation/analog-control-unit.md`, `Documentation/gain-volume.md` | doc sync |

## 9. Testing

Unit (pure math): same-device positive/negative delta; clamp at −80/+40;
missing anchor → 0; unreadable current volume → 0; UID mismatch → 0; muted
→ −120 regardless of anchor; status mapping for every branch; NaN input → 0.

Manual: calibrate at a known volume → volume down 20 % → "remaining minutes"
extends and status shows a negative delta; mute → status flips, dose freezes;
switch to an HDMI device → unavailable copy, delta 0; analog unit's VOLUME
knob moves the delta live.

## 10. Explicit non-goals

- Per-app or per-channel volume modeling.
- Modeling headphone sensitivity or fit (still disclosed as unmodeled).
- WDRC — this feature is its prerequisite (it makes `calibrationOffsetDBA`
  trustworthy enough to become audio-affecting later), not its first step.
