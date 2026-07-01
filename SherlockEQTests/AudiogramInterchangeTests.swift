//
//  AudiogramInterchangeTests.swift
//  SherlockEQTests
//
//  Round-trip and mapping invariants for the portable audiogram exchange
//  format that mirrors HealthKit's HKAudiogramSensitivityPoint. The HealthKit
//  bridge itself isn't exercised here (HealthKit doesn't link on macOS); these
//  cover the platform-neutral mapping the macOS app actually runs.
//

import Testing
import Foundation
@testable import SherlockEQ

@MainActor
struct AudiogramInterchangeTests {

    private static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private static func point(_ hz: Double, l: Double?, r: Double?) -> AudiogramSensitivityPoint {
        AudiogramSensitivityPoint(frequencyHz: hz, leftEardBHL: l, rightEardBHL: r)
    }

    // MARK: Combined points → per-ear arrays

    @Test func splitsCombinedPointsIntoPerEarThresholds() {
        let doc = AudiogramInterchange(points: [
            Self.point(1000, l: 30, r: 25),
            Self.point(4000, l: 50, r: 45),
        ])
        let (left, right) = doc.perEarThresholds()

        // Eight standard rows on each side, regardless of how many were measured.
        #expect(left.map(\.frequencyHz) == AudiogramPoint.standardFrequencies)
        #expect(right.map(\.frequencyHz) == AudiogramPoint.standardFrequencies)

        func threshold(_ pts: [AudiogramPoint], _ hz: Int) -> Double {
            pts.first { $0.frequencyHz == hz }!.thresholddBHL
        }
        #expect(threshold(left, 1000) == 30)
        #expect(threshold(right, 1000) == 25)
        #expect(threshold(left, 4000) == 50)
        #expect(threshold(right, 4000) == 45)
        // Unmeasured slots fall back to 0 dB HL (normal hearing).
        #expect(threshold(left, 250) == 0)
        #expect(threshold(right, 8000) == 0)
    }

    @Test func missingEarLeavesThatEarFlat() {
        // A right-ear-only measurement must not bleed into the left ear.
        let doc = AudiogramInterchange(points: [Self.point(2000, l: nil, r: 60)])
        let (left, right) = doc.perEarThresholds()
        #expect(left.allSatisfy { $0.thresholddBHL == 0 })
        #expect(right.first { $0.frequencyHz == 2000 }!.thresholddBHL == 60)
    }

    @Test func offGridFrequencySnapsToNearestStandardSlot() {
        // 990 Hz isn't a standard slot; it should land on 1000.
        let doc = AudiogramInterchange(points: [Self.point(990, l: 35, r: 35)])
        let (left, _) = doc.perEarThresholds()
        #expect(left.first { $0.frequencyHz == 1000 }!.thresholddBHL == 35)
    }

    @Test func extremeThresholdIsClampedToAudiometricRange() {
        // Matches the 0...110 dB HL bound the interactive ThresholdEditor
        // already enforces — an imported file shouldn't be able to carry an
        // implausible threshold past it.
        let doc = AudiogramInterchange(points: [
            Self.point(1000, l: 500, r: -30),
        ])
        let (left, right) = doc.perEarThresholds()
        #expect(left.first { $0.frequencyHz == 1000 }!.thresholddBHL == 110)
        #expect(right.first { $0.frequencyHz == 1000 }!.thresholddBHL == 0)
    }

    @Test func nonFiniteThresholdPointIsSkipped() {
        let doc = AudiogramInterchange(points: [
            Self.point(1000, l: .nan, r: 30),
        ])
        let (left, right) = doc.perEarThresholds()
        #expect(left.first { $0.frequencyHz == 1000 }!.thresholddBHL == 0)
        #expect(right.first { $0.frequencyHz == 1000 }!.thresholddBHL == 30)
    }

    @Test func nonFiniteOrOutOfRangeFrequencyPointIsSkippedNotCrashed() {
        // A corrupted/hand-edited import can carry NaN, infinite, or absurd
        // frequency values. Int(Double) traps on those — perEarThresholds()
        // must filter them out before converting, not crash the app.
        let doc = AudiogramInterchange(points: [
            Self.point(.nan, l: 40, r: 40),
            Self.point(.infinity, l: 45, r: 45),
            Self.point(1e26, l: 50, r: 50),
            Self.point(1000, l: 30, r: 30),
        ])
        let (left, right) = doc.perEarThresholds()
        #expect(left.first { $0.frequencyHz == 1000 }!.thresholddBHL == 30)
        #expect(right.first { $0.frequencyHz == 1000 }!.thresholddBHL == 30)
        // No malformed point should have landed on any other slot.
        #expect(left.allSatisfy { $0.frequencyHz == 1000 || $0.thresholddBHL == 0 })
        #expect(right.allSatisfy { $0.frequencyHz == 1000 || $0.thresholddBHL == 0 })
    }

    // MARK: Round-trip through the interchange

    @Test func perEarRoundTripPreservesMeasuredThresholds() {
        let measured: [Int: Double] = [250: 10, 1000: 30, 4000: 55]
        let left = AudiogramPoint.standardFrequencies.map {
            AudiogramPoint(frequencyHz: $0, thresholddBHL: measured[$0] ?? 0)
        }
        let right = AudiogramPoint.standardFrequencies.map {
            AudiogramPoint(frequencyHz: $0, thresholddBHL: (measured[$0] ?? 0) + 5)
        }

        let doc = AudiogramInterchange.from(left: left, right: right)
        let (left2, right2) = doc.perEarThresholds()

        #expect(left2 == left)
        #expect(right2 == right)
    }

    @Test func codableRoundTripIsStable() throws {
        let doc = AudiogramInterchange(
            source: "Apple Health",
            testDateISO8601: "2026-06-25T12:00:00Z",
            points: [Self.point(1000, l: 20, r: 25), Self.point(8000, l: 40, r: nil)]
        )
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(AudiogramInterchange.self, from: data)
        #expect(decoded == doc)
    }

    // MARK: Applying onto a HearingProfile

    @Test func applyingAudiogramSetsThresholdsAndDerivesCorrection() {
        let profile = HearingProfile.makeDefault()
        let doc = AudiogramInterchange(points: [
            Self.point(2000, l: 45, r: 45),
            Self.point(4000, l: 55, r: 55),
        ])

        let updated = profile.applyingAudiogram(doc, modifiedAt: Self.stamp)

        // Thresholds landed on both ears.
        #expect(updated.leftEar.thresholds.first { $0.frequencyHz == 4000 }!.thresholddBHL == 55)
        #expect(updated.rightEar.thresholds.first { $0.frequencyHz == 2000 }!.thresholddBHL == 45)

        // A measurable loss produces an active correction layer.
        #expect(updated.leftEar.correctionBands.contains { $0.enabled })
        #expect(updated.rightEar.correctionBands.contains { $0.enabled })

        // The derived correction equals a direct conversion of the new
        // thresholds. Compare with audiblyEquivalent, not ==: EQBand's
        // Equatable includes its random `id`, and each derivation mints fresh
        // UUIDs, so == never matches even when every audible field is identical.
        let expected = AudiogramConversion.bands(
            for: updated.leftEar.thresholds,
            compensationFactor: updated.compensationFactor
        )
        #expect(updated.leftEar.correctionBands.audiblyEquivalent(to: expected))

        #expect(updated.modifiedAt == Self.stamp)
    }

    @Test func flatAudiogramDerivesNoActiveCorrection() {
        let profile = HearingProfile.makeDefault()
        let doc = AudiogramInterchange.from(left: AudiogramPoint.flat, right: AudiogramPoint.flat)

        let updated = profile.applyingAudiogram(doc, modifiedAt: Self.stamp)

        #expect(!updated.leftEar.correctionBands.contains { $0.enabled })
        #expect(!updated.rightEar.correctionBands.contains { $0.enabled })
    }
}
