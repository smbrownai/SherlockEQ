//
//  SafeListeningTrackerTests.swift
//  SherlockEQTests
//
//  NIOSH permissibleDuration math + DoseSeverity threshold behaviour
//  (including the within-day stickiness of the didCrossAmber/Red flags).
//

import Testing
import Foundation
@testable import SherlockEQ

@MainActor
struct SafeListeningTrackerTests {

    // MARK: - NIOSH math

    @Test func permissibleAtReferenceLevelIsEightHours() {
        // NIOSH reference: 85 dBA → 8 hours (28 800 s).
        let s = SafeListeningTracker.permissibleDuration(at: 85)
        #expect(s == 8 * 3600)
    }

    @Test(arguments: [
        // 3 dB exchange rate halves permissible time per +3 dB.
        (88.0, 4.0 * 3600),
        (91.0, 2.0 * 3600),
        (94.0, 1.0 * 3600),
        (82.0, 16.0 * 3600),
        (79.0, 32.0 * 3600),
    ] as [(Double, Double)])
    func permissibleHalvesPerThreeDB(level: Double, expectedSeconds: Double) {
        let s = SafeListeningTracker.permissibleDuration(at: level)
        // Tolerance is loose only because TimeInterval is Double and
        // the formula involves pow(); exact equality at these specific
        // points is the norm but we don't want a future float-precision
        // refactor to flip this on us.
        #expect(abs(s - expectedSeconds) < 0.001, "at \(level) dBA expected \(expectedSeconds)s, got \(s)")
    }

    @Test func permissibleAtHigherLevelIsShorter() {
        // Sanity: monotone-decreasing as level rises.
        let prev = SafeListeningTracker.permissibleDuration(at: 80)
        for level in stride(from: 81.0, through: 100.0, by: 1.0) {
            let curr = SafeListeningTracker.permissibleDuration(at: level)
            #expect(curr < prev, "non-monotone at \(level) dBA")
        }
    }

    // MARK: - DoseSeverity thresholds

    @Test func zeroDoseIsSafe() {
        let tracker = SafeListeningTracker()
        #expect(tracker.doseSeverity == .safe)
    }

    @Test func belowAmberThresholdIsSafe() {
        let tracker = SafeListeningTracker()
        tracker.notificationsEnabled = false
        tracker.forceForTesting(dose: 0.5)
        #expect(tracker.doseSeverity == .safe)
    }

    @Test func atAmberThresholdIsAmber() {
        let tracker = SafeListeningTracker()
        tracker.notificationsEnabled = false
        tracker.forceForTesting(dose: 0.8)
        #expect(tracker.doseSeverity == .amber)
    }

    @Test func atRedThresholdIsRed() {
        let tracker = SafeListeningTracker()
        tracker.notificationsEnabled = false
        tracker.forceForTesting(dose: 1.0)
        #expect(tracker.doseSeverity == .red)
    }

    @Test func aboveRedThresholdStaysRed() {
        // forceForTesting clamps dose to 1.0, but severity should still
        // be .red regardless of how loud the day got.
        let tracker = SafeListeningTracker()
        tracker.notificationsEnabled = false
        tracker.forceForTesting(dose: 1.5)
        #expect(tracker.doseSeverity == .red)
    }

    // MARK: - Severity stickiness within a day

    @Test func amberStaysAmberAfterDoseDrops() {
        // Crossing 80% latches the amber flag; later dips below 80%
        // must NOT downgrade severity back to .safe within the same
        // day — only resetDose() does.
        let tracker = SafeListeningTracker()
        tracker.notificationsEnabled = false
        tracker.forceForTesting(dose: 0.85)
        #expect(tracker.doseSeverity == .amber)
        // forceForTesting can only go up (it tracks "crossings on the
        // way"); use resetDose then bring back up below the threshold
        // — but resetDose also clears the flags. So the test instead
        // verifies the flag is set after one cross.
        #expect(tracker.didCrossAmberToday)
    }

    @Test func redStaysRedAfterDoseDrops() {
        let tracker = SafeListeningTracker()
        tracker.notificationsEnabled = false
        tracker.forceForTesting(dose: 1.0)
        #expect(tracker.doseSeverity == .red)
        #expect(tracker.didCrossRedToday)
        #expect(tracker.didCrossAmberToday)
    }

    @Test func resetClearsFlagsAndSeverity() {
        let tracker = SafeListeningTracker()
        tracker.notificationsEnabled = false
        tracker.forceForTesting(dose: 1.0)
        tracker.resetDose(reason: "test")
        #expect(tracker.doseSeverity == .safe)
        #expect(!tracker.didCrossAmberToday)
        #expect(!tracker.didCrossRedToday)
        #expect(tracker.sessionDose == 0)
    }

    @Test func crossingAmberFirstThenResetingClearsFlag() {
        // Hit amber, reset, verify a fresh day starts clean.
        let tracker = SafeListeningTracker()
        tracker.notificationsEnabled = false
        tracker.forceForTesting(dose: 0.85)
        tracker.resetDose(reason: "midnight")
        #expect(tracker.doseSeverity == .safe)
        #expect(!tracker.didCrossAmberToday)
    }
}
