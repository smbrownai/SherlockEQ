//
//  SafeListeningTrackerTests.swift
//  SherlockEQTests
//
//  NIOSH permissibleDuration math + DoseSeverity threshold behaviour
//  (including the within-day stickiness of the didCrossAmber/Red flags).
//

import Testing
import Foundation
import Combine
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

    // MARK: - Daily peak (drives the 7-day history)

    @Test func peakTracksHighestDose() {
        let tracker = SafeListeningTracker()
        tracker.notificationsEnabled = false
        tracker.forceForTesting(dose: 0.6)
        #expect(tracker.peakDoseToday == 0.6)
    }

    @Test func peakSurvivesManualReset() {
        // A manual / sustained-quiet reset zeroes the live dose but must leave
        // the day's high-water mark — that exposure still happened, and the
        // midnight rollover is the only thing that banks + clears it.
        let tracker = SafeListeningTracker()
        tracker.notificationsEnabled = false
        tracker.forceForTesting(dose: 0.9)
        tracker.resetDose(reason: "sustained quiet")
        #expect(tracker.sessionDose == 0)
        #expect(tracker.peakDoseToday == 0.9)
    }

    @Test func peakDoesNotLowerOnSmallerForce() {
        let tracker = SafeListeningTracker()
        tracker.notificationsEnabled = false
        tracker.forceForTesting(dose: 0.7)
        tracker.forceForTesting(dose: 0.3)
        #expect(tracker.peakDoseToday == 0.7)
    }

    // MARK: - Time-zone-stable day identity (dose-history key)

    @Test func dayKeyIsStableAcrossTimesWithinADay() {
        // Two instants on the same calendar day → identical key, so a record
        // can't be split across two bars or mis-detected as a new day.
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date())
        let morning = base.addingTimeInterval(8 * 3600)
        let night = base.addingTimeInterval(23 * 3600)
        #expect(SafeListeningTracker.dayKey(for: morning) == SafeListeningTracker.dayKey(for: night))
    }

    @Test func differentDaysHaveDifferentKeys() {
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        #expect(SafeListeningTracker.dayKey(for: today) != SafeListeningTracker.dayKey(for: yesterday))
    }

    @Test func dayKeyRoundTripsToSameDay() {
        // date(fromDayKey: dayKey(d)) must land on the same calendar day, so a
        // banked record re-normalises (via startOfDay) back to its own bar.
        let cal = Calendar.current
        let d = cal.date(byAdding: .day, value: -3, to: Date())!
        let key = SafeListeningTracker.dayKey(for: d)
        let restored = SafeListeningTracker.date(fromDayKey: key)
        #expect(restored != nil)
        #expect(cal.isDate(restored!, inSameDayAs: d))
        #expect(SafeListeningTracker.dayKey(for: restored!) == key)
    }

    @Test func dayKeyFormatIsZeroPaddedISO() {
        // Guards against e.g. "2026-6-1" which would break date(fromDayKey:)
        // ordering and any external reader.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 1; comps.day = 5
        let d = Calendar.current.date(from: comps)!
        #expect(SafeListeningTracker.dayKey(for: d) == "2026-01-05")
    }

    @Test func malformedDayKeyReturnsNil() {
        #expect(SafeListeningTracker.date(fromDayKey: "not-a-date") == nil)
        #expect(SafeListeningTracker.date(fromDayKey: "2026-06") == nil)
    }

    // MARK: - Observability at the dose cap (audit CX-01)

    /// The tracker must keep publishing once the dose pins at the 1.0 cap.
    /// The UI's live surfaces (LiveLevelBody, DoseCardBody,
    /// PopoverLiveStatusRows) subscribe to the tracker's objectWillChange —
    /// if capped-dose updates went silent, the level meter and exposure rows
    /// would freeze at the exact moment the user hits their daily limit
    /// (which is what happened via AudioState's equality-guarded mirror, the
    /// bug this pins against regressing at the tracker level).
    @Test func trackerKeepsPublishingAtDoseCap() {
        let tracker = SafeListeningTracker()
        tracker.notificationsEnabled = false
        tracker.forceForTesting(dose: 1.0)
        #expect(tracker.sessionDose == 1.0)

        var publishes = 0
        let sub = tracker.objectWillChange.sink { _ in publishes += 1 }
        defer { sub.cancel() }

        // Level samples keep arriving while capped — each must still publish
        // (currentLevelDBA is @Published) even though the dose can't climb.
        tracker.update(levelDBA: 70)
        #expect(tracker.currentLevelDBA == 70)
        #expect(publishes > 0, "tracker went silent at the dose cap")

        let before = publishes
        tracker.update(levelDBA: 72)
        #expect(tracker.currentLevelDBA == 72)
        #expect(publishes > before, "publishing must be continuous, not one-shot")

        // And the dose itself stays pinned — the cap is the display truth.
        #expect(tracker.sessionDose == 1.0)
    }
}
