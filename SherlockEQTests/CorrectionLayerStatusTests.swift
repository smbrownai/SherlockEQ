//
//  CorrectionLayerStatusTests.swift
//  SherlockEQTests
//
//  Regression cover for a banner that claimed a headphone correction was "in
//  the Result" while the chain was bypassing it. The rule under test is
//  "loaded is not applied" — these pin the full truth table against
//  AudioState.applyBypassMask's behavior.
//

import Testing
import Foundation
@testable import SherlockEQ

@MainActor
struct CorrectionLayerStatusTests {

    private func profile(audiogram: Bool, headphone: Bool) -> HearingProfile {
        var p = HearingProfile.makeDefault(name: "Test")
        if audiogram {
            let band = EQBand(frequencyHz: 2000, gaindB: 4, bandwidth: 1.0,
                              filterType: .parametric, enabled: true)
            p.leftEar.correctionBands = [band]
            p.rightEar.correctionBands = [band]
        }
        if headphone {
            p.autoEQBands = [EQBand(frequencyHz: 100, gaindB: -3, bandwidth: 1.0,
                                    filterType: .parametric, enabled: true)]
            p.autoEQName = "Test Headphones"
        }
        return p
    }

    private func status(_ p: HearingProfile, master: Bool = true,
                        autoEQ: Bool = true) -> CorrectionLayerStatus {
        CorrectionLayerStatus(profile: p, masterEnabled: master, autoEQEnabled: autoEQ)
    }

    // MARK: - The reported bug

    /// The exact failure: a profile carrying a full headphone correction, with
    /// the AutoEQ stage bypassed. Nothing may claim it's being applied.
    @Test func bypassedHeadphoneCorrectionIsNotApplied() {
        let s = status(profile(audiogram: false, headphone: true), autoEQ: false)
        #expect(!s.headphone)
        #expect(!s.any, "a bypassed correction must not surface a banner")
        #expect(s.sourceNames.isEmpty)
    }

    @Test func enabledHeadphoneCorrectionIsApplied() {
        let s = status(profile(audiogram: false, headphone: true), autoEQ: true)
        #expect(s.headphone)
        #expect(s.any)
    }

    // MARK: - Master toggle drops everything

    /// Master off is the one case that takes the audiogram correction down
    /// too — the per-stage manual-EQ toggle deliberately doesn't.
    @Test func masterOffDropsBothLayers() {
        let s = status(profile(audiogram: true, headphone: true), master: false)
        #expect(!s.audiogram)
        #expect(!s.headphone)
        #expect(!s.any)
    }

    /// Master off wins even with the AutoEQ stage nominally enabled.
    @Test func masterOffOverridesTheAutoEQToggle() {
        let s = status(profile(audiogram: false, headphone: true),
                       master: false, autoEQ: true)
        #expect(!s.headphone)
    }

    // MARK: - The layers are independent

    /// Bypassing headphones must not silence the audiogram claim, and vice
    /// versa — a banner naming the wrong layer is the same class of bug.
    @Test func audiogramSurvivesTheAutoEQToggle() {
        let s = status(profile(audiogram: true, headphone: true), autoEQ: false)
        #expect(s.audiogram)
        #expect(!s.headphone)
        #expect(s.sourceNames == ["Hearing adjustment"])
    }

    @Test func headphoneAloneNamesOnlyItself() {
        let s = status(profile(audiogram: false, headphone: true))
        #expect(s.sourceNames == ["headphone correction"])
    }

    @Test func bothLayersListLowLevelFirst() {
        let s = status(profile(audiogram: true, headphone: true))
        #expect(s.sourceNames == ["Hearing adjustment", "headphone correction"],
                "cascade order: the hearing adjustment sits beneath the headphone correction")
    }

    // MARK: - Nothing configured

    @Test func bareProfileClaimsNothing() {
        let s = status(profile(audiogram: false, headphone: false))
        #expect(!s.any)
        #expect(s.sourceNames.isEmpty)
    }

    /// An empty (not nil) band array is "no correction", not "a correction of
    /// nothing" — the original check used `?? true` and this pins that edge.
    @Test func emptyAutoEQArrayIsNotACorrection() {
        var p = profile(audiogram: false, headphone: false)
        p.autoEQBands = []
        #expect(!status(p).headphone)
    }
}
