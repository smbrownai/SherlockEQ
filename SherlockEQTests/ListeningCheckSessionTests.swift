//
//  ListeningCheckSessionTests.swift
//  SherlockEQTests
//
//  The Listening Check's modified Hughson–Westlake state machine
//  (phase3-make-correction-land.md §4.3): staircase transitions, the
//  2-ascending-hits threshold rule, catch-trial bookkeeping, the 1 kHz
//  retest validity probe, ceiling → unmeasurable, and the dBFS ↔ dB HL
//  anchor math. Pure — no audio, no timers; catch scheduling injected.
//

import Testing
import Foundation
@testable import SherlockEQ

struct ListeningCheckSessionTests {

    /// Standard config: calibration 100 → ceiling min(−25, 80−100) = −25…
    /// no — 80−100 = −20, min(−25, −20) = −25 dBFS. Floor −85.
    private func makeSession(
        offset: Double = 100,
        catches: @escaping () -> Bool = { false }
    ) -> ListeningCheckSession {
        ListeningCheckSession(
            config: .init(
                ceilingDBFS: ListeningCheckSession.Config.safetyCeilingDBFS(
                    effectiveCalibrationOffsetDBA: offset),
                effectiveCalibrationOffsetDBA: offset
            ),
            catchDecider: catches
        )
    }

    private func currentTrial(_ s: ListeningCheckSession) -> ListeningCheckSession.Trial? {
        if case .presenting(let t) = s.phase { return t }
        return nil
    }

    /// Answer every trial with a simulated listener whose (per-frequency)
    /// true threshold is given in dBFS: hears iff level ≥ threshold.
    /// Runs until the phase leaves `.presenting` or `limit` trials elapse.
    @discardableResult
    private func autopilot(
        _ session: inout ListeningCheckSession,
        thresholdDBFS: (Double) -> Double,
        limit: Int = 2000
    ) -> Int {
        var trials = 0
        while case .presenting(let trial) = session.phase, trials < limit {
            trials += 1
            if case .earComplete = session.phase { break }
            let heard = !trial.isCatch && trial.levelDBFS >= thresholdDBFS(trial.frequencyHz)
            session.respond(heard: heard)
            if case .earComplete = session.phase {
                if session.completedEars.count == 1 { session.continueToNextEar() }
            }
        }
        return trials
    }

    // MARK: - Safety ceiling math

    @Test func safetyCeilingIsTheStricterOfTheTwoCaps() {
        // Default calibration 100: 80−100 = −20 → the −25 floor wins.
        #expect(ListeningCheckSession.Config.safetyCeilingDBFS(effectiveCalibrationOffsetDBA: 100) == -25)
        // Hot calibration 115: 80−115 = −35 → the SPL cap wins.
        #expect(ListeningCheckSession.Config.safetyCeilingDBFS(effectiveCalibrationOffsetDBA: 115) == -35)
    }

    // MARK: - Anchor math (§4.4)

    @Test func dbHLMappingRoundTrips() {
        let s = makeSession(offset: 100)
        // estimatedDBHL = (dBFS + offset) − RETSPL(f)
        // At 1 kHz (RETSPL 7.5): −67.5 dBFS + 100 − 7.5 = 25 dB HL.
        #expect(abs(s.dbHL(fromDBFS: -67.5, at: 1000) - 25) < 0.001)
        #expect(abs(s.dbFS(fromHL: 25, at: 1000) - (-67.5)) < 0.001)
    }

    // MARK: - Flow shape

    @Test func beginPresentsFamiliarizationAtOneKilohertz() {
        var s = makeSession()
        s.begin(firstEar: .left)
        let trial = currentTrial(s)
        #expect(trial?.isFamiliarization == true)
        #expect(trial?.frequencyHz == 1000)
        #expect(trial?.ear == .left)
        // Familiarization targets ~40 dB HL equivalent.
        #expect(abs(s.dbHL(fromDBFS: trial!.levelDBFS, at: 1000) - 40) < 0.001)
    }

    @Test func betterEarFirstOrdering() {
        var s = makeSession()
        s.begin(firstEar: .right)
        #expect(currentTrial(s)?.ear == .right)
    }

    @Test func fullRunVisitsAllFrequenciesOnBothEars() {
        var s = makeSession()
        s.begin(firstEar: .left)
        // Flat listener: hears everything at/above −70 dBFS.
        autopilot(&s, thresholdDBFS: { _ in -70 })
        #expect(s.phase == .finished)
        #expect(s.completedEars.count == 2)
        for ear in s.completedEars {
            #expect(ear.frequencyResults.map(\.frequencyHz)
                    == ListeningCheckSession.frequencySequence)
            #expect(!ear.lowReliability)
        }
    }

    // MARK: - Threshold accuracy (the point of the whole procedure)

    @Test func staircaseConvergesOnTheSimulatedThreshold() {
        var s = makeSession()
        s.begin(firstEar: .left)
        // Sloping loss: true threshold −70 dBFS below 3 kHz, −55 above.
        let truth: (Double) -> Double = { $0 >= 3000 ? -55 : -70 }
        autopilot(&s, thresholdDBFS: truth)
        #expect(s.phase == .finished)
        for ear in s.completedEars {
            for fr in ear.frequencyResults {
                let measured = try! #require(fr.thresholdDBFS)
                // H-W with 5 dB steps lands within one step of a
                // deterministic listener's true threshold.
                #expect(abs(measured - truth(fr.frequencyHz)) <= 5,
                        "\(fr.frequencyHz) Hz: measured \(measured)")
            }
        }
    }

    @Test func estimatedThresholdsConvertAndSort() {
        var s = makeSession(offset: 100)
        s.begin(firstEar: .left)
        autopilot(&s, thresholdDBFS: { _ in -70 })
        let points = s.estimatedThresholds(for: .left)
        #expect(points.count == 8)
        #expect(points.map(\.frequencyHz) == points.map(\.frequencyHz).sorted())
        // −70 dBFS at 1 kHz → 100 − 70 − 7.5 = 22.5 → rounds to 5-grid.
        let oneK = points.first { $0.frequencyHz == 1000 }
        #expect(oneK != nil)
        #expect(oneK!.thresholddBHL.truncatingRemainder(dividingBy: 5) == 0)
    }

    // MARK: - Ceiling / unmeasurable

    @Test func profoundLossRecordsUnmeasurableNotLouderTones() {
        var s = makeSession()
        s.begin(firstEar: .left)
        var maxPresented = -Double.infinity
        while case .presenting(let trial) = s.phase {
            if !trial.isCatch { maxPresented = max(maxPresented, trial.levelDBFS) }
            s.respond(heard: false)   // hears nothing, ever
            if case .earComplete = s.phase, s.completedEars.count == 1 {
                s.continueToNextEar()
            }
        }
        #expect(s.phase == .finished)
        // Do-no-harm: nothing was ever presented above the ceiling.
        #expect(maxPresented <= s.config.ceilingDBFS)
        // Familiarization never succeeded → ear aborted, flagged unreliable.
        #expect(s.completedEars.allSatisfy { $0.aborted && $0.lowReliability })
        #expect(s.estimatedThresholds(for: .left).isEmpty)
    }

    @Test func singleUnmeasurableFrequencyIsExcludedOthersSurvive() {
        var s = makeSession()
        s.begin(firstEar: .left)
        // Hears everything except 8 kHz (dead region).
        autopilot(&s, thresholdDBFS: { $0 == 8000 ? 999 : -70 })
        #expect(s.phase == .finished)
        let left = s.completedEars[0]
        let eightK = left.frequencyResults.first { $0.frequencyHz == 8000 }
        #expect(eightK?.thresholdDBFS == nil)
        #expect(s.estimatedThresholds(for: .left).count == 7)
        #expect(!s.estimatedThresholds(for: .left).contains { $0.frequencyHz == 8000 })
    }

    @Test func acuteHearingClampsAtFloor() {
        var s = makeSession()
        s.begin(firstEar: .left)
        autopilot(&s, thresholdDBFS: { _ in -200 })   // hears everything
        #expect(s.phase == .finished)
        for fr in s.completedEars[0].frequencyResults {
            #expect(fr.thresholdDBFS == s.config.floorDBFS)
        }
    }

    // MARK: - Catch trials

    @Test func falseAlarmsAreCountedAndFlagReliability() {
        var everyOther = false
        var s = makeSession(catches: {
            everyOther.toggle()
            return everyOther
        })
        s.begin(firstEar: .left)
        // Button-masher: responds to EVERYTHING, including silence.
        var trials = 0
        while case .presenting = s.phase, trials < 2000 {
            trials += 1
            s.respond(heard: true)
            if case .earComplete = s.phase, s.completedEars.count == 1 {
                s.continueToNextEar()
            }
        }
        #expect(s.phase == .finished)
        for ear in s.completedEars {
            #expect(ear.falseAlarms > ListeningCheckSession.falseAlarmLimit)
            #expect(ear.lowReliability)
        }
    }

    @Test func catchTrialsNeverChangeTheStaircaseLevel() {
        var forceCatch = true
        var s = makeSession(catches: { forceCatch })
        s.begin(firstEar: .left)
        // Familiarize first (no catches during familiarization).
        guard case .presenting(let fam) = s.phase, fam.isFamiliarization else {
            Issue.record("expected familiarization"); return
        }
        s.respond(heard: true)
        // Next: machine alternates catch/real (never two catches in a row).
        guard case .presenting(let t1) = s.phase else { Issue.record("t1"); return }
        #expect(t1.isCatch)
        s.respond(heard: false)          // correct rejection
        guard case .presenting(let t2) = s.phase else { Issue.record("t2"); return }
        #expect(!t2.isCatch)             // no catch-after-catch
        forceCatch = false
        let levelBefore = t2.levelDBFS
        s.respond(heard: true)
        guard case .presenting(let t3) = s.phase else { Issue.record("t3"); return }
        // Real response moved the staircase down; the catch never did.
        #expect(t3.levelDBFS == levelBefore - ListeningCheckSession.stepDownDB)
    }

    // MARK: - Retest validity (never averaged)

    @Test func consistentRetestLeavesNoFlagAndNoExtraPoint() {
        var s = makeSession()
        s.begin(firstEar: .left)
        autopilot(&s, thresholdDBFS: { _ in -70 })
        let left = s.completedEars[0]
        #expect(left.retestDeltaDB != nil)
        #expect(abs(left.retestDeltaDB!) <= ListeningCheckSession.retestToleranceDB)
        // The retest is a probe, not a data point: exactly one 1 kHz result.
        #expect(left.frequencyResults.filter { $0.frequencyHz == 1000 }.count == 1)
        #expect(!left.lowReliability)
    }

    @Test func divergentRetestFlagsLowReliability() {
        var s = makeSession()
        s.begin(firstEar: .left)
        // Listener whose 1 kHz threshold "drifts" 20 dB worse after the
        // first pass (attention lapse): keyed off how many results exist.
        var firstPassDone = false
        while case .presenting(let trial) = s.phase {
            if case .earComplete = s.phase { break }
            let base: Double = -70
            var threshold = base
            if trial.frequencyHz == 1000 && firstPassDone { threshold = base + 20 }
            s.respond(heard: !trial.isCatch && trial.levelDBFS >= threshold)
            if s.completedEars.isEmpty,
               case .presenting(let next) = s.phase,
               next.frequencyHz == 250 || firstPassDone {
                firstPassDone = true
            }
            if case .earComplete = s.phase, s.completedEars.count == 1 {
                s.continueToNextEar()
            }
        }
        #expect(s.phase == .finished)
        let left = s.completedEars[0]
        #expect(left.retestDeltaDB != nil)
        #expect(abs(left.retestDeltaDB!) > ListeningCheckSession.retestToleranceDB)
        #expect(left.lowReliability)
        // First measurement kept — never silently averaged.
        let oneK = left.frequencyResults.first { $0.frequencyHz == 1000 }!
        #expect(abs(oneK.thresholdDBFS! - (-70)) <= 5)
    }
}
