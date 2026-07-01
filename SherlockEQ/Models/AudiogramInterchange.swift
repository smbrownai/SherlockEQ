//
//  AudiogramInterchange.swift
//  SherlockEQ
//
//  A portable audiogram exchange format that mirrors HealthKit's
//  HKAudiogramSensitivityPoint (frequency + per-ear dB HL). It lets a
//  Health-stored audiogram round-trip into a HearingProfile WITHOUT the
//  macOS app importing HealthKit — HealthKit doesn't exist on macOS. An
//  iOS companion (where `canImport(HealthKit)` is true) maps an
//  HKAudiogramSample into this struct and hands it across (file /
//  pasteboard); the macOS side maps it onto a profile. The unit is dB HL
//  end to end — same as AudiogramPoint.thresholddBHL and HealthKit's
//  .decibelHearingLevel() — so there is no unit conversion on either side.
//

import Foundation

/// One audiometric point: a frequency and the threshold for each ear, in dB HL.
/// Both ears are optional — asymmetric / single-ear tests are valid, matching
/// how HKAudiogramSensitivityPoint exposes leftEarSensitivity / rightEarSensitivity.
struct AudiogramSensitivityPoint: Codable, Hashable {
    /// Double (not Int) so any HealthKit frequency is accepted, not just the
    /// app's standard eight. `perEarThresholds()` snaps it onto our grid.
    var frequencyHz: Double
    var leftEardBHL: Double?
    var rightEardBHL: Double?
}

/// A portable audiogram document — one file is one hearing test.
struct AudiogramInterchange: Codable, Hashable {
    var version: Int = 1
    var source: String?              // e.g. "Apple Health", "Audiologist report"
    var testDateISO8601: String?     // passed in; this type never reads the clock
    var points: [AudiogramSensitivityPoint]
}

// MARK: - Interchange ⇄ SherlockEQ per-ear thresholds

extension AudiogramInterchange {
    /// Split the combined points into SherlockEQ's two per-ear threshold arrays,
    /// snapping each frequency onto the app's standard audiometric set. Frequencies
    /// the test doesn't cover are left at 0 dB HL (normal); non-standard or off-grid
    /// frequencies map to the nearest standard slot. The result is UI-ready —
    /// exactly the eight standard rows, one `AudiogramPoint` each — so it drops
    /// straight into `EarProfile.thresholds`.
    func perEarThresholds() -> (left: [AudiogramPoint], right: [AudiogramPoint]) {
        func fold(_ pick: (AudiogramSensitivityPoint) -> Double?) -> [AudiogramPoint] {
            // Start flat (normal hearing), then overwrite the measured slots.
            var byFreq = Dictionary(
                uniqueKeysWithValues: AudiogramPoint.standardFrequencies.map { ($0, 0.0) }
            )
            for p in points {
                guard let value = pick(p), value.isFinite else { continue }
                // Reject non-finite or wildly out-of-range frequencies (e.g. from a
                // corrupted or hand-edited import) before the Int conversion below —
                // Int(Double) traps on NaN/infinite/out-of-Int-range values, which
                // would otherwise crash the app on a single bad row.
                guard p.frequencyHz.isFinite, (20...20_000).contains(p.frequencyHz) else { continue }
                let target = Int(p.frequencyHz.rounded())
                let slot = AudiogramPoint.standardFrequencies
                    .min { abs($0 - target) < abs($1 - target) }!
                // Same 0...110 dB HL bound the interactive ThresholdEditor already
                // enforces (ThresholdEditor.swift:49) — an imported file shouldn't
                // be able to carry an implausible threshold past that bound into
                // storage or a chart axis.
                byFreq[slot] = max(0, min(110, value))
            }
            return AudiogramPoint.standardFrequencies.map {
                AudiogramPoint(frequencyHz: $0, thresholddBHL: byFreq[$0] ?? 0)
            }
        }
        return (fold(\.leftEardBHL), fold(\.rightEardBHL))
    }

    /// Reverse mapping: a profile's two threshold arrays back into combined
    /// interchange points (for export to Health / sharing). Frequencies present
    /// in only one ear yield a point with the other ear nil.
    static func from(
        left: [AudiogramPoint],
        right: [AudiogramPoint],
        source: String? = nil,
        testDateISO8601: String? = nil
    ) -> AudiogramInterchange {
        let l = Dictionary(uniqueKeysWithValues: left.map  { ($0.frequencyHz, $0.thresholddBHL) })
        let r = Dictionary(uniqueKeysWithValues: right.map { ($0.frequencyHz, $0.thresholddBHL) })
        let freqs = Set(l.keys).union(r.keys).sorted()
        return AudiogramInterchange(
            source: source,
            testDateISO8601: testDateISO8601,
            points: freqs.map { f in
                AudiogramSensitivityPoint(
                    frequencyHz: Double(f),
                    leftEardBHL: l[f],
                    rightEardBHL: r[f]
                )
            }
        )
    }
}

// MARK: - Apply onto a HearingProfile

extension HearingProfile {
    /// Replace this profile's audiogram from an imported interchange and
    /// recompute the per-ear correction layer. Mirrors `backfillCorrection`
    /// and the AudiogramView edit binding so the engine cascade stays
    /// consistent: re-derive `correctionBands` from the new thresholds, then
    /// strip any stale derived bands out of `bands` so they can't apply twice.
    /// Pass a fresh `modifiedAt` — this type deliberately never reads the clock.
    func applyingAudiogram(_ doc: AudiogramInterchange, modifiedAt: Date) -> HearingProfile {
        var copy = self
        let (left, right) = doc.perEarThresholds()
        copy.leftEar.thresholds = left
        copy.rightEar.thresholds = right
        for ear in [\HearingProfile.leftEar, \HearingProfile.rightEar] {
            let derived = AudiogramConversion.bands(
                for: copy[keyPath: ear].thresholds,
                compensationFactor: copy.compensationFactor
            )
            copy[keyPath: ear].correctionBands = derived
            copy[keyPath: ear].bands = EQBandLookup.removingAudiogramBands(
                matching: derived,
                from: copy[keyPath: ear].bands
            )
        }
        copy.modifiedAt = modifiedAt
        return copy
    }
}

// MARK: - HealthKit bridge (iOS / watchOS companion target only)

#if canImport(HealthKit)
import HealthKit

extension AudiogramInterchange {
    /// Build interchange from a HealthKit audiogram sample. Compiles only where
    /// HealthKit exists (iOS / watchOS) — never in the macOS app target. The
    /// `dateFormatter` is injected so callers control the (clock-free) date
    /// string and the function stays testable.
    init(healthKitSample sample: HKAudiogramSample, dateFormatter: ISO8601DateFormatter) {
        let hearingLevel = HKUnit.decibelHearingLevel()   // == SherlockEQ's dB HL unit
        let hertz = HKUnit.hertz()
        self.init(
            version: 1,
            source: "Apple Health",
            testDateISO8601: dateFormatter.string(from: sample.startDate),
            points: sample.sensitivityPoints.map { point in
                AudiogramSensitivityPoint(
                    frequencyHz: point.frequency.doubleValue(for: hertz),
                    leftEardBHL: point.leftEarSensitivity?.doubleValue(for: hearingLevel),
                    rightEardBHL: point.rightEarSensitivity?.doubleValue(for: hearingLevel)
                )
            }
        )
    }
}
#endif
