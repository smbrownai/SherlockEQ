//
//  AcclimatizationRampTests.swift
//  SherlockEQTests
//
//  The acclimatization ramp (phase3-make-correction-land.md §5): 60 → 100 %
//  over 21 days, and the consumption-time strength model — stored
//  correctionBands are the FULL prescription; every consumer reads
//  `effectiveCorrectionBands` (target compensationFactor × ramp), which is
//  also what makes the compensation slider audible again (it previously
//  wrote a value nothing re-derived from).
//

import Testing
import Foundation
@testable import SherlockEQ

struct AcclimatizationRampTests {

    private func days(_ n: Double) -> TimeInterval { n * 86_400 }

    // MARK: - Ramp math

    @Test func nilStartMeansFullStrength() {
        #expect(AcclimatizationRamp.factor(start: nil) == 1.0)
        #expect(!AcclimatizationRamp.isRamping(start: nil))
    }

    @Test func dayZeroStartsAtSixtyPercent() {
        let now = Date()
        #expect(AcclimatizationRamp.factor(start: now, now: now) == 0.6)
    }

    @Test func midRampIsLinear() {
        let start = Date()
        // Halfway (10.5 days): 0.6 + 0.4 × 0.5 = 0.8
        let mid = start.addingTimeInterval(days(10.5))
        #expect(abs(AcclimatizationRamp.factor(start: start, now: mid) - 0.8) < 0.001)
    }

    @Test func completedRampClampsToFull() {
        let start = Date()
        let later = start.addingTimeInterval(days(30))
        #expect(AcclimatizationRamp.factor(start: start, now: later) == 1.0)
        #expect(!AcclimatizationRamp.isRamping(start: start, now: later))
    }

    @Test func futureStartClampsToStartFraction() {
        // Clock rolled back — never extrapolate below the day-zero strength.
        let start = Date().addingTimeInterval(days(5))
        #expect(AcclimatizationRamp.factor(start: start, now: Date()) == 0.6)
    }

    @Test func dayNumberIsOneBasedAndClamped() {
        let start = Date()
        #expect(AcclimatizationRamp.dayNumber(start: start, now: start) == 1)
        #expect(AcclimatizationRamp.dayNumber(start: start, now: start.addingTimeInterval(days(5.5))) == 6)
        #expect(AcclimatizationRamp.dayNumber(start: start, now: start.addingTimeInterval(days(100))) == 21)
    }

    // MARK: - Effective correction (drawn = heard source of truth)

    private func profileWithCorrection(
        gainDB: Double = 10, compensation: Double = 1.0, stamp: Date? = nil
    ) -> HearingProfile {
        var p = HearingProfile.makeDefault(name: "Test")
        p.compensationFactor = compensation
        p.acclimatizationStartDate = stamp
        let band = EQBand(frequencyHz: 4000, gaindB: gainDB, bandwidth: 1.0, filterType: .parametric, enabled: true)
        p.leftEar.correctionBands = [band]
        p.rightEar.correctionBands = [band]
        return p
    }

    @Test func effectiveBandsScaleByTargetTimesRamp() {
        let now = Date()
        // Target 0.8, day-zero ramp 0.6 → effective 0.48.
        let p = profileWithCorrection(gainDB: 10, compensation: 0.8, stamp: now)
        let effective = p.effectiveCorrectionBands(now: now)
        #expect(abs(effective.left[0].gaindB - 4.8) < 0.001)
        #expect(abs(effective.right[0].gaindB - 4.8) < 0.001)
        // Stored prescription untouched.
        #expect(p.leftEar.correctionBands[0].gaindB == 10)
    }

    @Test func legacyProfileWithoutStampGetsTargetStrengthOnly() {
        let p = profileWithCorrection(gainDB: 10, compensation: 0.5, stamp: nil)
        #expect(abs(p.effectiveCorrectionBands().left[0].gaindB - 5.0) < 0.001)
    }

    @Test func compensationSliderIsAudibleAgain() {
        // The regression this architecture fixes: changing the target
        // strength must change what consumers receive, with no re-derivation
        // step in between.
        let half = profileWithCorrection(gainDB: 10, compensation: 0.5)
        let full = profileWithCorrection(gainDB: 10, compensation: 1.0)
        #expect(half.effectiveCorrectionBands().left[0].gaindB
                != full.effectiveCorrectionBands().left[0].gaindB)
    }

    // MARK: - First-application stamping

    @Test func firstAudiogramStampsAndTargetsFullStrength() {
        var p = HearingProfile.makeDefault(name: "Test")
        p.compensationFactor = 0.5
        p.leftEar.correctionBands = [EQBand(frequencyHz: 4000, gaindB: 8, bandwidth: 1.0, filterType: .parametric, enabled: true)]
        p.startAcclimatizationIfFirstAudiogram(hadCorrectionBefore: false)
        #expect(p.compensationFactor == 1.0)
        #expect(p.acclimatizationStartDate != nil)
    }

    @Test func ongoingAudiogramEditKeepsStrengthAndClock() {
        var p = profileWithCorrection(compensation: 0.7, stamp: Date().addingTimeInterval(-days(10)))
        let originalStamp = p.acclimatizationStartDate
        p.startAcclimatizationIfFirstAudiogram(hadCorrectionBefore: true)
        #expect(p.compensationFactor == 0.7)
        #expect(p.acclimatizationStartDate == originalStamp)
    }

    @Test func flatAudiogramNeverStamps() {
        var p = HearingProfile.makeDefault(name: "Test")   // no correction derived
        p.startAcclimatizationIfFirstAudiogram(hadCorrectionBefore: false)
        #expect(p.acclimatizationStartDate == nil)
    }

    // MARK: - Legacy decode normalization

    @Test func legacyBakedInStrengthNormalizesToFullOnDecode() throws {
        // A profile stored by an old build: correction derived WITH cf=0.5
        // baked in. Decode must re-derive the stored layer at full strength
        // (thresholds are the source of truth), leaving the old cf as the
        // consumption-time target — net audible result unchanged (±fit
        // linearity), slider now live.
        var legacy = HearingProfile.makeDefault(name: "Legacy")
        legacy.compensationFactor = 0.5
        let loss = AudiogramPoint.standardFrequencies.map {
            AudiogramPoint(frequencyHz: $0, thresholddBHL: $0 >= 2000 ? 40 : 10)
        }
        legacy.leftEar.thresholds = loss
        legacy.rightEar.thresholds = loss
        legacy.leftEar.correctionBands = AudiogramConversion.bands(for: loss, compensationFactor: 0.5)
        legacy.rightEar.correctionBands = AudiogramConversion.bands(for: loss, compensationFactor: 0.5)

        let decoded = try JSONDecoder().decode(
            HearingProfile.self,
            from: JSONEncoder().encode(legacy)
        )
        let expected = AudiogramConversion.bands(for: loss, compensationFactor: 1.0)
        #expect(decoded.leftEar.correctionBands.audiblyEquivalent(to: expected))
        #expect(decoded.compensationFactor == 0.5)   // target untouched
        #expect(decoded.acclimatizationStartDate == nil)   // legacy: no ramp
    }

    // MARK: - Clear + strength labelling (audit CX-06/07)

    /// Clearing returns the whole hearing-adjustment layer to its
    /// never-entered state — including the strength dial. The reset is
    /// deliberate: re-entry force-resets the target to 1.0 anyway (first-
    /// audiogram semantics), so clearing makes that explicit at "Clear" time
    /// instead of silently discarding a lowered strength on the next entry.
    @Test func clearAudiogramResetsTheFullAdjustmentLayer() {
        var p = HearingProfile.makeDefault(name: "Cleared")
        var loss = AudiogramPoint.flat
        loss[4].thresholddBHL = 40   // 3 kHz dip → real derived correction
        p.applyMeasuredAudiogram(left: loss, right: loss, source: .listeningCheck)
        p.compensationFactor = 0.4   // user lowered the target afterwards
        #expect(p.hasEnteredAudiogram)
        #expect(!p.leftEar.correctionBands.isEmpty)
        #expect(p.acclimatizationStartDate != nil)

        p.clearAudiogram()

        #expect(!p.hasEnteredAudiogram)
        #expect(p.leftEar.thresholds == AudiogramPoint.flat)
        #expect(p.rightEar.thresholds == AudiogramPoint.flat)
        #expect(p.leftEar.correctionBands.isEmpty)
        #expect(p.rightEar.correctionBands.isEmpty)
        #expect(p.audiogramSource == .manual)
        #expect(p.acclimatizationStartDate == nil)
        #expect(p.compensationFactor == 1.0)
    }

    /// Clearing must not touch anything outside the adjustment layer.
    @Test func clearAudiogramLeavesManualEQAndNotchAlone() {
        var p = HearingProfile.makeDefault(name: "Kept")
        var loss = AudiogramPoint.flat
        loss[4].thresholddBHL = 40
        p.applyMeasuredAudiogram(left: loss, right: loss, source: .manual)
        let manual = EQBand(frequencyHz: 250, gaindB: -3, bandwidth: 1.0,
                            filterType: .parametric, enabled: true)
        p.leftEar.bands.append(manual)
        p.leftNotch.enabled = true
        p.leftNotch.frequencyHz = 6000

        p.clearAudiogram()

        #expect(p.leftEar.bands.contains { $0.frequencyHz == 250 && $0.gaindB == -3 })
        #expect(p.leftNotch.enabled)
        #expect(p.leftNotch.frequencyHz == 6000)
    }

    /// One wording rule for the strength readout: single figure once the
    /// ramp completes, target + current while they differ (audit CX-06 —
    /// two screens showed different numbers under the same word).
    @Test func strengthLabelCollapsesWhenTargetEqualsEffective() {
        #expect(AdjustmentStrengthLabel.text(target: 1.0, effective: 1.0)
                == "Adjustment strength 100%")
        #expect(AdjustmentStrengthLabel.text(target: 1.0, effective: 0.61)
                == "Adjustment strength 100% · currently 61%")
        #expect(AdjustmentStrengthLabel.text(target: 0.8, effective: 0.48)
                == "Adjustment strength 80% · currently 48%")
        // Rounding to the same whole percent reads as one figure.
        #expect(AdjustmentStrengthLabel.text(target: 1.0, effective: 0.999)
                == "Adjustment strength 100%")
    }
}
