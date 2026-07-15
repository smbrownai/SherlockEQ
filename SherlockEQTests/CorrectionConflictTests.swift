//
//  CorrectionConflictTests.swift
//  SherlockEQTests
//
//  Truth table for the notch-vs-correction conflict check
//  (phase3-make-correction-land.md §6): fires only when the audiogram
//  correction boosts ≥ +4 dB at the notch center AND the notch cuts
//  ≤ −6 dB — the structural presbycusis collision, not ordinary overlap.
//

import Testing
import Foundation
@testable import SherlockEQ

struct CorrectionConflictTests {

    private func correction(at hz: Double, gainDB: Double) -> [EQBand] {
        [EQBand(frequencyHz: hz, gaindB: gainDB, bandwidth: 1.0, filterType: .parametric, enabled: true)]
    }

    private func notch(at hz: Double, depth: Double, enabled: Bool = true) -> TinnitusNotch {
        TinnitusNotch(enabled: enabled, frequencyHz: hz, depthdB: depth, qWidth: .medium)
    }

    // MARK: - The structural collision

    @Test func boostUnderNotchFires() {
        // +8 dB correction bell at 4 kHz, −10 dB notch at 4 kHz — the
        // presbycusis case: notch pitch in the region of maximum loss.
        let conflict = CorrectionConflict.evaluate(
            notch: notch(at: 4000, depth: -10),
            correctionBands: correction(at: 4000, gainDB: 8)
        )
        #expect(conflict != nil)
        #expect(abs((conflict?.correctionBoostDB ?? 0) - 8) < 0.5)
        #expect(conflict?.notchDepthDB == -10)
        #expect(conflict?.message.contains("4.0 kHz") == true)
    }

    @Test func thresholdBoundariesInclusive() {
        // Exactly +4 dB correction and exactly −6 dB notch → fires.
        let conflict = CorrectionConflict.evaluate(
            notch: notch(at: 1000, depth: -6),
            correctionBands: correction(at: 1000, gainDB: 4)
        )
        #expect(conflict != nil)
    }

    // MARK: - Silences

    @Test func mildCorrectionIsSilent() {
        #expect(CorrectionConflict.evaluate(
            notch: notch(at: 4000, depth: -12),
            correctionBands: correction(at: 4000, gainDB: 2)
        ) == nil)
    }

    @Test func shallowNotchIsSilent() {
        #expect(CorrectionConflict.evaluate(
            notch: notch(at: 4000, depth: -3),
            correctionBands: correction(at: 4000, gainDB: 10)
        ) == nil)
    }

    @Test func disabledNotchIsSilent() {
        #expect(CorrectionConflict.evaluate(
            notch: notch(at: 4000, depth: -12, enabled: false),
            correctionBands: correction(at: 4000, gainDB: 10)
        ) == nil)
    }

    @Test func offFrequencyOverlapIsSilent() {
        // Correction boosting 1 kHz contributes ~nothing at a 12 kHz notch.
        #expect(CorrectionConflict.evaluate(
            notch: notch(at: 12_000, depth: -12),
            correctionBands: correction(at: 1000, gainDB: 10)
        ) == nil)
    }

    @Test func emptyCorrectionIsSilent() {
        #expect(CorrectionConflict.evaluate(
            notch: notch(at: 4000, depth: -12),
            correctionBands: []
        ) == nil)
    }

    // MARK: - Per-ear independence

    @Test func earsEvaluateIndependently() {
        var profile = HearingProfile.makeDefault(name: "Test")
        profile.leftNotch = notch(at: 4000, depth: -10)
        profile.rightNotch = notch(at: 4000, depth: -10)
        profile.leftEar.correctionBands = correction(at: 4000, gainDB: 8)
        profile.rightEar.correctionBands = []   // no correction on the right

        let result = CorrectionConflict.evaluate(profile: profile)
        #expect(result.left != nil)
        #expect(result.right == nil)
    }
}
