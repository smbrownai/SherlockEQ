//
//  AudiogramConversionTests.swift
//  SherlockEQTests
//
//  NAL-R prescription + overlap-fit invariants for audiogram → EQ conversion.
//  The realised composite curve (BiquadResponse) is what the engine applies,
//  so most checks assert against the *composite*, not raw per-band gains.
//

import Testing
import Foundation
@testable import SherlockEQ

struct AudiogramConversionTests {

    private static func audiogram(_ byFreq: [Int: Double]) -> [AudiogramPoint] {
        AudiogramPoint.standardFrequencies.map {
            AudiogramPoint(frequencyHz: $0, thresholddBHL: byFreq[$0] ?? 0)
        }
    }

    private static func flat(_ dbHL: Double) -> [AudiogramPoint] {
        AudiogramPoint.standardFrequencies.map {
            AudiogramPoint(frequencyHz: $0, thresholddBHL: dbHL)
        }
    }

    private static func composite(_ bands: [EQBand], at hz: Double) -> Double {
        BiquadResponse.compositeMagnitudeDB(at: hz, bands: bands)
    }

    // MARK: Normal hearing → no correction

    @Test func normalHearingProducesFlatChain() {
        let bands = AudiogramConversion.bands(for: Self.flat(0), compensationFactor: 1.0)
        #expect(bands.allSatisfy { !$0.enabled || abs($0.gaindB) < 0.25 })
        for f in [250.0, 1000, 4000, 8000] {
            #expect(abs(Self.composite(bands.filter(\.enabled), at: f)) < 0.5)
        }
    }

    @Test func subThresholdLossLeavesThatBandFlat() {
        // 3 dB at 250 is below the 5 dB actionable floor; the rest are normal.
        let bands = AudiogramConversion.bands(for: Self.audiogram([250: 3]), compensationFactor: 1.0)
        let at250 = bands.first { $0.frequencyHz == 250 }
        #expect(at250?.enabled == false || abs(at250?.gaindB ?? 0) < 0.25)
    }

    // MARK: NAL-R formula realised in the composite

    @Test func nalrTargetIsRealisedAtMeasuredFrequencies() {
        // Flat 40 dB HL loss. X = 0.05·(40+40+40) = 6.
        //   REIG(1k) = 6 + 0.31·40 + 1   = 19.4
        //   REIG(4k) = 6 + 0.31·40 + (−2) = 16.4
        //   REIG(250)= 6 + 0.31·40 + (−17)= 1.4
        let bands = AudiogramConversion.bands(for: Self.flat(40), compensationFactor: 1.0)
            .filter(\.enabled)
        #expect(abs(Self.composite(bands, at: 1000) - 19.4) < 0.6)
        #expect(abs(Self.composite(bands, at: 4000) - 16.4) < 0.6)
        #expect(abs(Self.composite(bands, at: 250) - 1.4) < 0.6)
    }

    @Test func overlapFitMatchesTargetOnSlopingLoss() {
        // Ski-slope high-frequency loss — the closely spaced 3/4/6/8 kHz bells
        // are where naive gains over-boost; the fit must still land on target.
        let ag = Self.audiogram([250: 5, 500: 10, 1000: 20, 2000: 35, 3000: 45, 4000: 55, 6000: 60, 8000: 60])
        let cf = 1.0
        let X = 0.05 * (10.0 + 20.0 + 35.0)
        let k: [Double: Double] = [250: -17, 500: -8, 1000: 1, 2000: -1, 3000: -2, 4000: -2, 6000: -2, 8000: -2]
        let htl: [Double: Double] = [250: 5, 500: 10, 1000: 20, 2000: 35, 3000: 45, 4000: 55, 6000: 60, 8000: 60]
        let bands = AudiogramConversion.bands(for: ag, compensationFactor: cf).filter(\.enabled)
        for f in [500.0, 2000, 4000, 6000, 8000] {
            let target = cf * (X + 0.31 * htl[f]! + k[f]!)
            #expect(abs(Self.composite(bands, at: f) - target) < 0.75)
        }
    }

    // MARK: Strength, clamping, shape

    @Test func compensationFactorScalesTheCorrection() {
        let full = AudiogramConversion.bands(for: Self.flat(40), compensationFactor: 1.0).filter(\.enabled)
        let half = AudiogramConversion.bands(for: Self.flat(40), compensationFactor: 0.5).filter(\.enabled)
        let cFull = Self.composite(full, at: 1000)
        let cHalf = Self.composite(half, at: 1000)
        #expect(abs(cHalf - 0.5 * cFull) < 0.6)
    }

    @Test func zeroStrengthDisablesEverything() {
        let bands = AudiogramConversion.bands(for: Self.flat(60), compensationFactor: 0.0)
        #expect(bands.allSatisfy { !$0.enabled || abs($0.gaindB) < 0.25 })
    }

    @Test func gainsRespectPerBandCeiling() {
        let bands = AudiogramConversion.bands(for: Self.flat(120), compensationFactor: 1.0)
        #expect(bands.allSatisfy { abs($0.gaindB) <= AudiogramConversion.perBandCeilingDB + 1e-9 })
    }

    @Test func highFrequencyLossDeEmphasisesLows() {
        // NAL-R's k(250) = −17 means a steep high-frequency loss should NOT
        // boost the lows much (and may cut them) — the audiology point that
        // distinguishes it from the old flat half-gain rule.
        let ag = Self.audiogram([250: 0, 500: 0, 1000: 10, 2000: 30, 3000: 50, 4000: 60, 6000: 65, 8000: 65])
        let bands = AudiogramConversion.bands(for: ag, compensationFactor: 1.0).filter(\.enabled)
        #expect(Self.composite(bands, at: 250) < 5.0)
        #expect(Self.composite(bands, at: 6000) > Self.composite(bands, at: 250))
    }

    @Test func emitsOneBandPerAudiogramFrequency() {
        let bands = AudiogramConversion.bands(for: Self.flat(30), compensationFactor: 1.0)
        #expect(bands.count == AudiogramPoint.standardFrequencies.count)
        #expect(bands.allSatisfy { $0.filterType == .parametric })
    }
}
