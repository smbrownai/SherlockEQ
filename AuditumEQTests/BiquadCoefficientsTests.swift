//
//  BiquadCoefficientsTests.swift
//  AuditumEQTests
//
//  Invariants for the shared Audio EQ Cookbook math. BiquadCascade
//  (audio path) and BiquadResponse (drawn EQ curve) both route through
//  this — a sign flip in any case here would silently make the curve
//  disagree with the audio for the whole app.
//

import Testing
import Foundation
@testable import AuditumEQ

struct BiquadCoefficientsTests {

    // MARK: - Helpers

    private static let SR: Double = 48_000

    private static func band(
        _ type: EQFilterType,
        hz: Double,
        gainDB: Double = 0,
        Q: Double = 0.707
    ) -> EQBand {
        EQBand(
            frequencyHz: hz,
            gaindB: gainDB,
            bandwidth: Q,
            filterType: type,
            enabled: true
        )
    }

    // MARK: - Identity-at-zero-gain

    @Test func parametricAtZeroGainIsIdentity() {
        // A = pow(10, 0/40) = 1, so:
        //   b0 = 1 + alpha*1 = 1 + alpha == a0 = 1 + alpha/1
        //   b1 = -2cos(w0) == a1
        //   b2 = 1 - alpha == a2
        // i.e. all b coeffs equal their a counterparts → unit transfer function.
        let c = BiquadCoefficients.cookbook(for: Self.band(.parametric, hz: 1000, gainDB: 0), sampleRate: Self.SR)
        #expect(abs(c.b0 - c.a0) < 1e-12)
        #expect(abs(c.b1 - c.a1) < 1e-12)
        #expect(abs(c.b2 - c.a2) < 1e-12)
    }

    @Test(arguments: [
        (EQFilterType.lowShelf,  60.0),
        (EQFilterType.highShelf, 8000.0),
    ] as [(EQFilterType, Double)])
    func shelfAtZeroGainIsIdentity(filterType: EQFilterType, hz: Double) {
        // A = 1 collapses the shelf coefficients to a unit transfer too.
        let c = BiquadCoefficients.cookbook(for: Self.band(filterType, hz: hz, gainDB: 0), sampleRate: Self.SR)
        #expect(abs(c.b0 - c.a0) < 1e-12)
        #expect(abs(c.b1 - c.a1) < 1e-12)
        #expect(abs(c.b2 - c.a2) < 1e-12)
    }

    // MARK: - Gain clamp

    @Test func gainClampPositive() {
        // Past +gainClampDB the cookbook should treat the band as if it
        // had exactly +gainClampDB. Two cookbook results at gain=clamp
        // and gain=clamp+100 should be byte-identical.
        let atClamp = BiquadCoefficients.cookbook(
            for: Self.band(.parametric, hz: 1000, gainDB: BiquadCoefficients.gainClampDB),
            sampleRate: Self.SR
        )
        let overClamp = BiquadCoefficients.cookbook(
            for: Self.band(.parametric, hz: 1000, gainDB: BiquadCoefficients.gainClampDB + 100),
            sampleRate: Self.SR
        )
        #expect(atClamp.b0 == overClamp.b0)
        #expect(atClamp.a0 == overClamp.a0)
    }

    @Test func gainClampNegative() {
        let atClamp = BiquadCoefficients.cookbook(
            for: Self.band(.parametric, hz: 1000, gainDB: -BiquadCoefficients.gainClampDB),
            sampleRate: Self.SR
        )
        let overClamp = BiquadCoefficients.cookbook(
            for: Self.band(.parametric, hz: 1000, gainDB: -BiquadCoefficients.gainClampDB - 100),
            sampleRate: Self.SR
        )
        #expect(atClamp.b0 == overClamp.b0)
        #expect(atClamp.a0 == overClamp.a0)
    }

    // MARK: - Frequency clamp

    @Test func frequencyClampLow() {
        // Anything below 20 Hz clamps to 20.
        let at20 = BiquadCoefficients.cookbook(for: Self.band(.parametric, hz: 20, gainDB: 6), sampleRate: Self.SR)
        let at5  = BiquadCoefficients.cookbook(for: Self.band(.parametric, hz: 5,  gainDB: 6), sampleRate: Self.SR)
        #expect(at20.b0 == at5.b0)
        #expect(at20.a1 == at5.a1)
    }

    @Test func frequencyClampHigh() {
        // Anything at or above Nyquist clamps to SR/2 − 1.
        let nyquistMinus1 = BiquadCoefficients.cookbook(for: Self.band(.parametric, hz: Self.SR / 2 - 1, gainDB: 6), sampleRate: Self.SR)
        let pastNyquist   = BiquadCoefficients.cookbook(for: Self.band(.parametric, hz: Self.SR,         gainDB: 6), sampleRate: Self.SR)
        #expect(nyquistMinus1.b0 == pastNyquist.b0)
        #expect(nyquistMinus1.a1 == pastNyquist.a1)
    }

    // MARK: - Notch shape

    @Test func notchCoefficientsAreGainIndependent() {
        // The cookbook notch's b coefficients don't depend on gain
        // (b0=1, b1=-2cos(w0), b2=1). Changing gainDB must leave them
        // identical; only `a` is affected via alpha → bandwidth.
        let c0 = BiquadCoefficients.cookbook(for: Self.band(.notch, hz: 4000, gainDB: 0,  Q: 5), sampleRate: Self.SR)
        let c6 = BiquadCoefficients.cookbook(for: Self.band(.notch, hz: 4000, gainDB: 12, Q: 5), sampleRate: Self.SR)
        #expect(c0.b0 == c6.b0)
        #expect(c0.b1 == c6.b1)
        #expect(c0.b2 == c6.b2)
    }

    // MARK: - Low/high-pass at DC and Nyquist

    @Test func lowPassPassesDC() {
        // At DC (w=0), |H(1)| = (b0+b1+b2) / (a0+a1+a2) should be ~1
        // for a low-pass filter.
        let c = BiquadCoefficients.cookbook(for: Self.band(.lowPass, hz: 1000, gainDB: 0, Q: 0.707), sampleRate: Self.SR)
        let numAtDC = c.b0 + c.b1 + c.b2
        let denAtDC = c.a0 + c.a1 + c.a2
        let magAtDC = numAtDC / denAtDC
        #expect(abs(magAtDC - 1.0) < 0.01)
    }

    @Test func highPassPassesNyquist() {
        // At Nyquist (w=π), |H(-1)| = (b0-b1+b2) / (a0-a1+a2) should be ~1
        // for a high-pass filter.
        let c = BiquadCoefficients.cookbook(for: Self.band(.highPass, hz: 1000, gainDB: 0, Q: 0.707), sampleRate: Self.SR)
        let numAtNyq = c.b0 - c.b1 + c.b2
        let denAtNyq = c.a0 - c.a1 + c.a2
        let magAtNyq = numAtNyq / denAtNyq
        #expect(abs(magAtNyq - 1.0) < 0.01)
    }

    @Test func lowPassBlocksNyquist() {
        // |H(-1)| should be ~0 for a low-pass at SR/2.
        let c = BiquadCoefficients.cookbook(for: Self.band(.lowPass, hz: 1000, gainDB: 0, Q: 0.707), sampleRate: Self.SR)
        let numAtNyq = c.b0 - c.b1 + c.b2
        let denAtNyq = c.a0 - c.a1 + c.a2
        let magAtNyq = numAtNyq / denAtNyq
        #expect(abs(magAtNyq) < 0.1)
    }

    @Test func highPassBlocksDC() {
        let c = BiquadCoefficients.cookbook(for: Self.band(.highPass, hz: 1000, gainDB: 0, Q: 0.707), sampleRate: Self.SR)
        let numAtDC = c.b0 + c.b1 + c.b2
        let denAtDC = c.a0 + c.a1 + c.a2
        let magAtDC = numAtDC / denAtDC
        #expect(abs(magAtDC) < 0.1)
    }

    // MARK: - a0 never zero

    @Test(arguments: [
        EQFilterType.parametric,
        .lowShelf, .highShelf, .notch, .bandPass, .lowPass, .highPass,
    ])
    func a0IsNeverZero(filterType: EQFilterType) {
        // a0 == 0 would NaN the entire cascade. The cookbook should
        // keep a0 strictly positive for every realistic input.
        for hz in [20.0, 100.0, 1000.0, 5000.0, 20_000.0] {
            for gain in [-30.0, -6.0, 0.0, 6.0, 30.0] {
                for Q in [0.1, 0.707, 5.0] {
                    let b = EQBand(frequencyHz: hz, gaindB: gain, bandwidth: Q, filterType: filterType, enabled: true)
                    let c = BiquadCoefficients.cookbook(for: b, sampleRate: Self.SR)
                    #expect(c.a0 > 1e-12, "a0 collapsed for \(filterType) @ \(hz) Hz, \(gain) dB, Q=\(Q)")
                }
            }
        }
    }
}
