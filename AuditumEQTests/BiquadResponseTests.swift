//
//  BiquadResponseTests.swift
//  AuditumEQTests
//
//  Magnitude-domain invariants for the drawn EQ curve. Pairs with
//  BiquadCoefficientsTests — those check the raw coefficients; these
//  check that |H(e^jw)| math on top behaves how the canvas relies on it.
//

import Testing
import Foundation
@testable import AuditumEQ

struct BiquadResponseTests {

    private static let SR: Double = 48_000

    private static func band(
        _ type: EQFilterType,
        hz: Double,
        gainDB: Double,
        Q: Double = 1.0,
        enabled: Bool = true
    ) -> EQBand {
        EQBand(
            frequencyHz: hz,
            gaindB: gainDB,
            bandwidth: Q,
            filterType: type,
            enabled: enabled
        )
    }

    // MARK: - Single parametric peak / cut

    @Test func parametricBoostsByItsGainAtCenter() {
        // A parametric band of +12 dB at f0 should produce ~+12 dB
        // magnitude at f0 (small tolerance for digital warping at
        // 48 kHz and finite-Q peak shape).
        let b = Self.band(.parametric, hz: 1000, gainDB: 12, Q: 1.0)
        let dB = BiquadResponse.magnitudeDB(at: 1000, band: b, sampleRate: Self.SR)
        #expect(abs(dB - 12) < 0.5, "expected ~+12 dB at center, got \(dB)")
    }

    @Test func parametricCutsByItsGainAtCenter() {
        let b = Self.band(.parametric, hz: 4000, gainDB: -9, Q: 1.0)
        let dB = BiquadResponse.magnitudeDB(at: 4000, band: b, sampleRate: Self.SR)
        #expect(abs(dB - -9) < 0.5)
    }

    // MARK: - Composite additivity

    @Test func plusSixAndMinusSixCancel() {
        // Two parametric bands at the same center frequency / Q with
        // equal-and-opposite gains should approximately cancel in dB
        // at the center (true reciprocal at f0; further out the shapes
        // diverge slightly because the filter is causal & digital).
        let plus  = Self.band(.parametric, hz: 2000, gainDB: 6, Q: 1.0)
        let minus = Self.band(.parametric, hz: 2000, gainDB: -6, Q: 1.0)
        let total = BiquadResponse.compositeMagnitudeDB(at: 2000, bands: [plus, minus], sampleRate: Self.SR)
        #expect(abs(total) < 0.5, "expected ~0 dB sum at center, got \(total)")
    }

    @Test func disabledBandsContributeZero() {
        // A disabled band must not affect the curve at all. Two
        // identical curves — one with an extra disabled +12 dB band —
        // should produce identical magnitudes.
        let active = Self.band(.parametric, hz: 1000, gainDB: 4, Q: 1.0)
        let off    = Self.band(.parametric, hz: 1000, gainDB: 12, Q: 1.0, enabled: false)
        let dBOnly     = BiquadResponse.compositeMagnitudeDB(at: 1000, bands: [active],       sampleRate: Self.SR)
        let dBPlusOff  = BiquadResponse.compositeMagnitudeDB(at: 1000, bands: [active, off],  sampleRate: Self.SR)
        #expect(dBOnly == dBPlusOff)
    }

    @Test func emptyChainIsFlat() {
        // No bands → 0 dB at every frequency.
        for hz in [20.0, 250.0, 1000.0, 5000.0, 20_000.0] {
            let dB = BiquadResponse.compositeMagnitudeDB(at: hz, bands: [], sampleRate: Self.SR)
            #expect(dB == 0)
        }
    }

    @Test func zeroGainBandIsFlat() {
        // A parametric / shelf at gain 0 should yield ~0 dB everywhere.
        let b = Self.band(.parametric, hz: 1000, gainDB: 0, Q: 1.0)
        for hz in [100.0, 500.0, 1000.0, 4000.0, 12_000.0] {
            let dB = BiquadResponse.magnitudeDB(at: hz, band: b, sampleRate: Self.SR)
            #expect(abs(dB) < 0.01, "non-flat magnitude (\(dB) dB) at \(hz) Hz for zero-gain parametric")
        }
    }

    // MARK: - Shelves

    @Test func lowShelfPositiveGainBoostsLowEnd() {
        // +6 dB low-shelf at 250 Hz: below the corner, magnitude
        // should approach +6 dB. At a couple octaves above the corner
        // it should approach 0 dB.
        let s = Self.band(.lowShelf, hz: 250, gainDB: 6, Q: 0.707)
        let lowSide  = BiquadResponse.magnitudeDB(at: 40,    band: s, sampleRate: Self.SR)
        let highSide = BiquadResponse.magnitudeDB(at: 4000,  band: s, sampleRate: Self.SR)
        #expect(lowSide > 5)
        #expect(abs(highSide) < 1)
    }

    @Test func highShelfPositiveGainBoostsHighEnd() {
        let s = Self.band(.highShelf, hz: 5000, gainDB: 6, Q: 0.707)
        let lowSide  = BiquadResponse.magnitudeDB(at: 500,   band: s, sampleRate: Self.SR)
        let highSide = BiquadResponse.magnitudeDB(at: 12_000, band: s, sampleRate: Self.SR)
        #expect(abs(lowSide) < 1)
        #expect(highSide > 5)
    }

    // MARK: - No NaN propagation

    @Test func neverProducesNaN() {
        // Sanity sweep — every filter type, a range of (hz, gain, Q),
        // and a range of query frequencies. Any NaN here would
        // immediately blank the EQ curve in the UI.
        for type in EQFilterType.allCases {
            for hz in [20.0, 1000.0, 20_000.0] {
                for gain in [-30.0, 0.0, 30.0] {
                    for Q in [0.1, 1.0, 10.0] {
                        let b = EQBand(frequencyHz: hz, gaindB: gain, bandwidth: Q, filterType: type, enabled: true)
                        for queryHz in [20.0, 500.0, 4000.0, 20_000.0] {
                            let dB = BiquadResponse.magnitudeDB(at: queryHz, band: b, sampleRate: Self.SR)
                            #expect(!dB.isNaN, "NaN at \(queryHz) Hz for \(type) (\(hz) Hz, \(gain) dB, Q=\(Q))")
                        }
                    }
                }
            }
        }
    }
}
