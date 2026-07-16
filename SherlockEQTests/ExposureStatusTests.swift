import Testing
@testable import SherlockEQ

/// Guards the "never claim safe when you don't know" rule that the Safe
/// Listening screen and the menu-bar popover both render. These are
/// safety-adjacent: a regression here doesn't crash anything, it just quietly
/// starts asserting a measurement that was never taken.
struct ExposureStatusTests {

    private let floor = ExposureStatus.audioFloorDBA   // 31 dBA

    // MARK: - unknown: no audio AND nothing accumulated

    @Test func silentAndNothingAccumulatedIsUnknown() {
        #expect(ExposureStatus.resolve(sessionDose: 0, levelDBA: 0,
                                       hasCalibration: false) == .unknown)
        // Calibration doesn't manufacture a measurement out of nothing.
        #expect(ExposureStatus.resolve(sessionDose: 0, levelDBA: 0,
                                       hasCalibration: true) == .unknown)
    }

    @Test func belowTheAudioFloorStillCountsAsSilent() {
        #expect(ExposureStatus.resolve(sessionDose: 0, levelDBA: floor - 0.1,
                                       hasCalibration: true) == .unknown)
    }

    @Test func atTheAudioFloorCountsAsReceivingAudio() {
        // Boundary is inclusive — at the floor we're measuring, not unknown.
        #expect(ExposureStatus.resolve(sessionDose: 0, levelDBA: floor,
                                       hasCalibration: true) == .tracked)
    }

    // MARK: - the asymmetry: accumulated exposure survives the audio stopping

    @Test func accumulatedDoseIsNotUnknownOnceAudioStops() {
        // The listening genuinely happened; going quiet doesn't unmeasure it.
        #expect(ExposureStatus.resolve(sessionDose: 0.24, levelDBA: 0,
                                       hasCalibration: true) == .tracked)
        #expect(ExposureStatus.resolve(sessionDose: 0.24, levelDBA: 0,
                                       hasCalibration: false) == .approximate)
    }

    // MARK: - approximate vs tracked

    @Test func audioWithoutCalibrationIsApproximate() {
        #expect(ExposureStatus.resolve(sessionDose: 0.03, levelDBA: 70,
                                       hasCalibration: false) == .approximate)
    }

    @Test func audioWithCalibrationIsTracked() {
        #expect(ExposureStatus.resolve(sessionDose: 0.03, levelDBA: 70,
                                       hasCalibration: true) == .tracked)
    }

    /// The specific bug this rule exists to prevent: playing audio, zero dose
    /// so far, uncalibrated — must NOT read as a confident tracked estimate.
    @Test func playingButZeroDoseUncalibratedIsNeverTracked() {
        let status = ExposureStatus.resolve(sessionDose: 0, levelDBA: 65,
                                            hasCalibration: false)
        #expect(status == .approximate)
        #expect(status != .tracked)
    }
}
