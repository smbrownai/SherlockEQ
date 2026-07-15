//
//  AdaptiveCorrectionTests.swift
//  SherlockEQTests
//
//  Phase 4 step 1 (phase4-adaptive-correction.md §8): the prescription's
//  safety invariants (§7.2 #1–3) and the filterbank's flatness invariant
//  (§7.2 #4) — all provable pure, before any engine wiring exists.
//

import Testing
import Foundation
@testable import SherlockEQ

// MARK: - Prescription

struct AdaptivePrescriptionTests {

    private typealias P = AdaptiveCorrectionPrescription

    private func band(g65: Double, cr: Double) -> P.BandParameters {
        P.BandParameters(g65DB: g65, cr: cr)
    }

    // MARK: CR mapping

    @Test func compressionRatioMapsLossAndClamps() {
        #expect(P.compressionRatio(htl: 0) == 1)
        #expect(abs(P.compressionRatio(htl: 30) - 1.5) < 0.001)
        #expect(abs(P.compressionRatio(htl: 60) - 2.0) < 0.001)
        #expect(P.compressionRatio(htl: 120) == P.compressionRatioCap)
        #expect(P.compressionRatio(htl: -20) == 1)          // better-than-normal → linear
        #expect(P.compressionRatio(htl: .nan) == 1)
    }

    // MARK: Invariant 2 — the NAL-R anchor

    @Test func gainAtReferenceLevelEqualsTheAnchor() {
        for g65 in [0.0, 3, 8, 15] {
            for cr in [1.0, 1.5, 2.5] {
                let g = P.gainDB(band: band(g65: g65, cr: cr),
                                 inputSPL: P.referenceSPL, strength: 1, calibrated: true)
                #expect(abs(g - g65) < 0.001, "g65 \(g65) cr \(cr)")
            }
        }
    }

    // MARK: Invariant 3 — monotone non-increasing in level

    @Test func gainNeverIncreasesWithLevel() {
        let b = band(g65: 12, cr: 2.2)
        var previous = Double.infinity
        for level in stride(from: 20.0, through: 115.0, by: 1.0) {
            let g = P.gainDB(band: b, inputSPL: level, strength: 1, calibrated: true)
            #expect(g <= previous + 1e-9, "level \(level)")
            previous = g
        }
    }

    // MARK: Knee behavior

    @Test func gainHoldsConstantBelowTheLowKnee() {
        let b = band(g65: 8, cr: 2.0)
        let atKnee = P.gainDB(band: b, inputSPL: P.kneeLowSPL, strength: 1, calibrated: true)
        for level in [10.0, 30, 44.9] {
            #expect(P.gainDB(band: b, inputSPL: level, strength: 1, calibrated: true) == atKnee)
        }
    }

    @Test func gainStopsTaperingAboveTheHighKnee() {
        let b = band(g65: 8, cr: 2.0)
        let atKnee = P.gainDB(band: b, inputSPL: P.kneeHighSPL, strength: 1, calibrated: true)
        for level in [95.0, 110, 140] {
            #expect(P.gainDB(band: b, inputSPL: level, strength: 1, calibrated: true) == atKnee)
        }
    }

    // MARK: Invariant 1 — caps, under any inputs whatsoever

    @Test func extraGainOverTheAnchorIsCapped() {
        // g65 5, CR 2.5: uncapped quiet gain would be 5 + 20·0.6 = 17;
        // the +10 extra cap trims it to 15.
        let g = P.gainDB(band: band(g65: 5, cr: 2.5),
                         inputSPL: 20, strength: 1, calibrated: true)
        #expect(abs(g - 15) < 0.001)
    }

    @Test func reducedDepthModeTightensTheExtraCap() {
        // Same setup, uncalibrated: extra capped at +4 → 9 dB.
        let g = P.gainDB(band: band(g65: 5, cr: 2.5),
                         inputSPL: 20, strength: 1, calibrated: false)
        #expect(abs(g - 9) < 0.001)
    }

    @Test func absoluteCapHoldsAgainstAdversarialInputs() {
        // Fuzz the whole input space — nothing may ever exceed the cap.
        let g65s: [Double] = [0, 10, 24, 40, 500]
        let crs: [Double] = [1, 2.5, 10, 100]
        let levels: [Double] = [-50, 0, 20, 45, 65, 90, 200]
        let strengths: [Double] = [0, 0.6, 1, 2, 100]
        for g65 in g65s {
            for cr in crs {
                for level in levels {
                    for strength in strengths {
                        let g = P.gainDB(band: band(g65: g65, cr: cr),
                                         inputSPL: level, strength: strength, calibrated: true)
                        #expect(g >= 0)
                        #expect(g <= P.absoluteCapDB, "g65 \(g65) cr \(cr) L \(level) s \(strength)")
                    }
                }
            }
        }
    }

    @Test func nonFiniteInputsProduceUnity() {
        let good = band(g65: 8, cr: 2)
        #expect(P.gainDB(band: band(g65: .nan, cr: 2), inputSPL: 50, strength: 1, calibrated: true) == 0)
        #expect(P.gainDB(band: band(g65: 8, cr: .infinity), inputSPL: 50, strength: 1, calibrated: true) == 0)
        #expect(P.gainDB(band: good, inputSPL: .nan, strength: 1, calibrated: true) == 0)
        #expect(P.gainDB(band: good, inputSPL: 50, strength: .nan, calibrated: true) == 0)
    }

    // MARK: Strength / ramp integration

    @Test func strengthScalesTheWholeGain() {
        let b = band(g65: 10, cr: 2)
        let full = P.gainDB(band: b, inputSPL: 50, strength: 1, calibrated: true)
        let ramped = P.gainDB(band: b, inputSPL: 50, strength: 0.6, calibrated: true)
        #expect(abs(ramped - full * 0.6) < 0.001)
        #expect(P.gainDB(band: b, inputSPL: 50, strength: 0, calibrated: true) == 0)
    }

    // MARK: HTL interpolation + band parameters

    @Test func htlInterpolatesInLogFrequencyAndClampsEdges() {
        let points = [
            AudiogramPoint(frequencyHz: 1000, thresholddBHL: 20),
            AudiogramPoint(frequencyHz: 4000, thresholddBHL: 60),
        ]
        #expect(P.interpolatedHTL(points, at: 1000) == 20)
        #expect(P.interpolatedHTL(points, at: 4000) == 60)
        // 2000 Hz is halfway in log space between 1 k and 4 k.
        #expect(abs(P.interpolatedHTL(points, at: 2000) - 40) < 0.001)
        #expect(P.interpolatedHTL(points, at: 250) == 20)      // edge clamp
        #expect(P.interpolatedHTL(points, at: 16_000) == 60)   // edge clamp
        #expect(P.interpolatedHTL([], at: 1000) == 0)
    }

    @Test func bandParametersAnchorToTheRealisedSteadyCurve() {
        // Sloping loss → derive the full-strength Steady correction, then
        // check every band's anchor equals that curve at the band center —
        // the invariant that makes Adaptive == Steady at 65 dB SPL.
        let loss = AudiogramPoint.standardFrequencies.map {
            AudiogramPoint(frequencyHz: $0, thresholddBHL: $0 >= 2000 ? 45 : 15)
        }
        let correction = AudiogramConversion.bands(for: loss, compensationFactor: 1.0)
        let params = P.bandParameters(thresholds: loss, correctionBands: correction)
        #expect(params.count == AdaptiveFilterbank.bandCount)
        for (i, center) in AdaptiveFilterbank.bandCenters.enumerated() {
            let steady = max(0, BiquadResponse.compositeMagnitudeDB(at: center, bands: correction))
            #expect(abs(params[i].g65DB - steady) < 0.001, "center \(center)")
            #expect(params[i].cr >= 1 && params[i].cr <= P.compressionRatioCap)
        }
        // High-loss bands compress harder than low-loss bands.
        #expect(params[4].cr > params[0].cr)
    }

    @Test func emptyCorrectionYieldsUnityAnchors() {
        let params = P.bandParameters(thresholds: [], correctionBands: [])
        #expect(params.allSatisfy { $0.g65DB == 0 && $0.cr == 1 })
    }
}

// MARK: - Filterbank

struct AdaptiveFilterbankTests {

    private let sampleRate = 48_000.0

    /// Steady-sine probe: process `total` samples, measure RMS of the last
    /// half (past the transient), return output/input level in dB.
    private func probeGainDB(
        _ bank: AdaptiveFilterbank,
        frequency: Double,
        gains: [Float],
        total: Int = 16_384
    ) -> Double {
        bank.reset()
        var samples = [Float](repeating: 0, count: total)
        for i in 0..<total {
            samples[i] = Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate))
        }
        samples.withUnsafeMutableBufferPointer { buf in
            bank.process(buf.baseAddress!, frameCount: total, gainsLinear: gains)
        }
        let tail = samples.suffix(total / 2)
        let rms = sqrt(tail.reduce(0) { $0 + Double($1) * Double($1) } / Double(tail.count))
        let inputRMS = 1.0 / 2.0.squareRoot()
        return 20 * log10(max(rms, 1e-12) / inputRMS)
    }

    private var unity: [Float] { [1, 1, 1, 1, 1, 1] }

    // MARK: Invariant 4 — unity sum is flat

    @Test func unityGainSumIsFlatAcrossTheSpectrum() {
        let bank = AdaptiveFilterbank(sampleRate: sampleRate)
        // Log-spaced probes, deliberately including every crossover.
        var freqs: [Double] = AdaptiveFilterbank.crossoverHz
        var f = 25.0
        while f < 19_000 { freqs.append(f); f *= 1.35 }
        for frequency in freqs {
            let g = probeGainDB(bank, frequency: frequency, gains: unity)
            #expect(abs(g) <= 0.5, "\(Int(frequency)) Hz: \(g) dB")
        }
    }

    @Test func perBandGainLandsOnItsBandAndNowhereElse() {
        let bank = AdaptiveFilterbank(sampleRate: sampleRate)
        // +12 dB on band 2 (710–1400 Hz, center 1 kHz). A one-octave band's
        // center carries LR4 skirt contributions from its unity neighbors,
        // diluting a LONE boost by ~2–3 dB (measured 9.1 dB) — that's the
        // crossover doing its job. Real gain profiles are smooth across
        // bands (audiograms are), where the dilution cancels — the
        // smooth-profile test below pins that stronger guarantee.
        var gains = unity
        gains[2] = Float(pow(10.0, 12.0 / 20.0))
        let onBand = probeGainDB(bank, frequency: 1000, gains: gains)
        #expect(onBand > 8.5 && onBand <= 12.5, "on-band \(onBand) dB")
        // Two-plus crossovers away: untouched (LR4 isolation; measured
        // ~0.005 dB).
        #expect(abs(probeGainDB(bank, frequency: 100, gains: gains)) < 0.1)
        #expect(abs(probeGainDB(bank, frequency: 12_000, gains: gains)) < 0.1)

        // The top band (> 5.6 kHz) has only ONE neighboring skirt, so deep
        // in-band (12 kHz) the boost comes through essentially intact.
        var topGains = unity
        topGains[5] = Float(pow(10.0, 12.0 / 20.0))
        let topBand = probeGainDB(bank, frequency: 12_000, gains: topGains)
        #expect(abs(topBand - 12) < 0.75, "top band \(topBand) dB")
    }

    @Test func smoothGainProfileTracksItsTargetExactly() {
        // Equal gains on every band = the allpass sum times the gain: the
        // realised response must hit the target everywhere. This is the
        // real-use guarantee — audiogram-derived gains vary smoothly, and
        // neighbors reinforce instead of diluting.
        let bank = AdaptiveFilterbank(sampleRate: sampleRate)
        let boosted = [Float](repeating: Float(pow(10.0, 12.0 / 20.0)), count: 6)
        for frequency in [40.0, 250, 1000, 2800, 8000, 15_000] {
            let g = probeGainDB(bank, frequency: frequency, gains: boosted)
            #expect(abs(g - 12) <= 0.5, "\(Int(frequency)) Hz: \(g) dB")
        }
    }

    @Test func crossoverPointSitsBetweenNeighboringBandGains() {
        let bank = AdaptiveFilterbank(sampleRate: sampleRate)
        // Bands 2 and 3 at +12 and 0: at the 1400 Hz crossover the LR4
        // halves each contribute −6 dB, so the sum lands mid-way-ish —
        // smooth transition, no notch, no peak beyond the louder side.
        var gains = unity
        gains[2] = Float(pow(10.0, 12.0 / 20.0))
        let atCrossover = probeGainDB(bank, frequency: 1400, gains: gains)
        #expect(atCrossover > 0.0 - 0.5)
        #expect(atCrossover < 12.0 + 0.5)
    }

    @Test func zeroGainsProduceSilence() {
        let bank = AdaptiveFilterbank(sampleRate: sampleRate)
        let g = probeGainDB(bank, frequency: 1000, gains: [0, 0, 0, 0, 0, 0])
        #expect(g < -80)
    }

    @Test func resetClearsAllState() {
        let bank = AdaptiveFilterbank(sampleRate: sampleRate)
        // Excite with an impulse…
        var impulse = [Float](repeating: 0, count: 64)
        impulse[0] = 1
        impulse.withUnsafeMutableBufferPointer { buf in
            bank.process(buf.baseAddress!, frameCount: 64, gainsLinear: unity)
        }
        bank.reset()
        // …then silence must stay exactly silent.
        var silence = [Float](repeating: 0, count: 256)
        silence.withUnsafeMutableBufferPointer { buf in
            bank.process(buf.baseAddress!, frameCount: 256, gainsLinear: unity)
        }
        #expect(silence.allSatisfy { $0 == 0 })
    }

    @Test func reconfigureForNewSampleRateStaysFlat() {
        let bank = AdaptiveFilterbank(sampleRate: 48_000)
        bank.configure(sampleRate: 44_100)
        bank.reset()
        let total = 16_384
        var samples = [Float](repeating: 0, count: total)
        for i in 0..<total {
            samples[i] = Float(sin(2 * Double.pi * 1000 * Double(i) / 44_100))
        }
        samples.withUnsafeMutableBufferPointer { buf in
            bank.process(buf.baseAddress!, frameCount: total, gainsLinear: unity)
        }
        let tail = samples.suffix(8192)
        let rms = sqrt(tail.reduce(0) { $0 + Double($1) * Double($1) } / Double(tail.count))
        let level = 20 * log10(rms * 2.0.squareRoot())
        #expect(abs(level) <= 0.5)
    }
}
