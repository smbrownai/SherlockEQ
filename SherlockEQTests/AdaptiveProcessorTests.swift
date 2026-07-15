//
//  AdaptiveProcessorTests.swift
//  SherlockEQTests
//
//  Phase 4 step 2 (phase4-adaptive-correction.md §8, processor bullets):
//  the realtime wrapper's behavior — bypass bit-exactness (§7.2 #5),
//  the NAL-R anchor at processor level (#2), level-following gains (#3),
//  caps under real signal (#1), ballistics, stability, and telemetry.
//
//  Convention: offset 100 → a sine of peak amplitude a presents a band
//  level of ≈ 20·log10(a) − 3 dBFS (RMS), i.e. estimated SPL ≈
//  97 + 20·log10(a). Tolerances account for LR4 skirt spill (~±1 dB).
//

import Testing
import Foundation
@testable import SherlockEQ

struct AdaptiveProcessorTests {

    private let sampleRate = 48_000.0
    private typealias P = AdaptiveCorrectionPrescription

    /// Six-band parameters with a uniform anchor and CR — keeps expected
    /// values easy to derive by hand.
    private func uniformBands(g65: Double, cr: Double) -> [P.BandParameters] {
        (0..<AdaptiveFilterbank.bandCount).map { _ in
            P.BandParameters(g65DB: g65, cr: cr)
        }
    }

    private func makeProcessor(
        bands: [P.BandParameters],
        strength: Double = 1,
        calibrated: Bool = true,
        offset: Double = 100,
        enabled: Bool = true
    ) -> AdaptiveCorrectionProcessor {
        let p = AdaptiveCorrectionProcessor(sampleRate: sampleRate)
        p.configure(bands: bands, strength: strength, calibrated: calibrated,
                    offsetDBA: offset, enabled: enabled)
        return p
    }

    /// Run a steady sine through the processor and return the output/input
    /// level ratio in dB, measured over the last `measure` samples (past
    /// detector + smoother settling).
    private func steadyGainDB(
        _ processor: AdaptiveCorrectionProcessor,
        frequency: Double,
        amplitude: Double,
        total: Int = 48_000,           // 1 s — well past all time constants
        measure: Int = 12_000
    ) -> Double {
        var samples = [Float](repeating: 0, count: total)
        for i in 0..<total {
            samples[i] = Float(amplitude * sin(2 * Double.pi * frequency * Double(i) / sampleRate))
        }
        // Feed in render-sized buffers like the engine would.
        samples.withUnsafeMutableBufferPointer { buf in
            var i = 0
            while i < total {
                let chunk = min(1024, total - i)
                processor.process(buf.baseAddress! + i, frameCount: chunk)
                i += chunk
            }
        }
        let tail = samples.suffix(measure)
        let rms = sqrt(tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(measure))
        let inputRMS = amplitude / 2.0.squareRoot()
        return 20 * log10(max(rms, 1e-12) / max(inputRMS, 1e-12))
    }

    /// Amplitude whose 1 kHz band level estimates roughly `spl` dB SPL at
    /// offset 100 (peak ≈ RMS + 3 dB).
    private func amplitude(forSPL spl: Double) -> Double {
        pow(10.0, (spl - 100 + 3) / 20.0)
    }

    /// Per-tone amplitude so that a tone AT a band center presents that
    /// band with ≈ `spl` dB SPL (the +2.5 compensates the interior bands'
    /// own LR4 skirt loss at their centers).
    private func toneAmplitude(bandSPL spl: Double) -> Double {
        pow(10.0, (spl - 100 + 3 + 2.5) / 20.0)
    }

    /// Six simultaneous tones, one per band center, all bands at ≈ equal
    /// SPL — the broadband real-use shape where per-band gains are uniform
    /// and the composite output gain equals the prescription. (A LONE tone
    /// reads as "quiet" in neighboring bands, whose higher quiet-gain then
    /// applies to its skirts — real, bounded-by-caps multiband behavior
    /// covered by §7.1's narrowband row, but the wrong probe for anchor
    /// equivalence.)
    private func steadyMultiToneGainDB(
        _ processor: AdaptiveCorrectionProcessor,
        bandSPL: Double,
        total: Int = 48_000,
        measure: Int = 12_000
    ) -> Double {
        let amp = toneAmplitude(bandSPL: bandSPL)
        var samples = [Float](repeating: 0, count: total)
        for i in 0..<total {
            var v = 0.0
            for center in AdaptiveFilterbank.bandCenters {
                v += amp * sin(2 * Double.pi * center * Double(i) / sampleRate)
            }
            samples[i] = Float(v)
        }
        let inputRMS = amp / 2.0.squareRoot() * Double(AdaptiveFilterbank.bandCount).squareRoot()
        samples.withUnsafeMutableBufferPointer { buf in
            var i = 0
            while i < total {
                let chunk = min(1024, total - i)
                processor.process(buf.baseAddress! + i, frameCount: chunk)
                i += chunk
            }
        }
        let tail = samples.suffix(measure)
        let rms = sqrt(tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(measure))
        return 20 * log10(max(rms, 1e-12) / inputRMS)
    }

    // MARK: - Invariant 5: bypass / disabled are bit-exact

    @Test func disabledIsBitExactPassthrough() {
        let p = makeProcessor(bands: uniformBands(g65: 10, cr: 2), enabled: false)
        var samples = (0..<1024).map { Float(sin(Double($0) * 0.1)) }
        let original = samples
        samples.withUnsafeMutableBufferPointer { buf in
            p.process(buf.baseAddress!, frameCount: 1024)
        }
        #expect(samples == original)
    }

    @Test func bypassIsBitExactPassthrough() {
        let p = makeProcessor(bands: uniformBands(g65: 10, cr: 2))
        p.setBypassed(true)
        var samples = (0..<1024).map { Float(sin(Double($0) * 0.1)) }
        let original = samples
        samples.withUnsafeMutableBufferPointer { buf in
            p.process(buf.baseAddress!, frameCount: 1024)
        }
        #expect(samples == original)
        #expect(p.currentGainMilliDB(band: 2) == 0)
    }

    // MARK: - Invariant 2: the anchor, end to end

    @Test func moderateInputGetsTheNALRAnchorGain() {
        // All bands at 65 dB SPL, g65 = 8: steady-state composite ≈ +8 dB —
        // Adaptive == Steady at moderate level, through the whole processor.
        let p = makeProcessor(bands: uniformBands(g65: 8, cr: 2))
        let g = steadyMultiToneGainDB(p, bandSPL: 65)
        #expect(abs(g - 8) < 1.5, "measured \(g) dB")
    }

    // MARK: - Invariant 3: level-following, in the right direction

    @Test func quietInputGetsMoreGainLoudGetsLess() {
        let bands = uniformBands(g65: 8, cr: 2)
        let quiet = steadyMultiToneGainDB(makeProcessor(bands: bands), bandSPL: 50)
        let moderate = steadyMultiToneGainDB(makeProcessor(bands: bands), bandSPL: 65)
        let loud = steadyMultiToneGainDB(makeProcessor(bands: bands), bandSPL: 85)
        #expect(quiet > moderate + 3, "quiet \(quiet) vs moderate \(moderate)")
        #expect(loud < moderate - 3, "loud \(loud) vs moderate \(moderate)")
        // Slope sanity: CR 2 → (1 − 1/2) = 0.5 dB of gain change per input
        // dB. 15 dB quieter → ≈ +7.5 dB more gain (within tolerance).
        #expect(abs((quiet - moderate) - 7.5) < 2.0)
    }

    // MARK: - Invariant 1: caps under real signal

    @Test func gainNeverExceedsTheCapsOnRealAudio() {
        // Absurd anchor: prescription clamps at the absolute cap; the
        // processed gain must respect it even for a whisper-level input.
        let p = makeProcessor(bands: uniformBands(g65: 100, cr: 2.5))
        let g = steadyGainDB(p, frequency: 1000, amplitude: amplitude(forSPL: 30))
        #expect(g <= P.absoluteCapDB + 1.0, "measured \(g) dB")
    }

    @Test func reducedDepthModeLimitsExtraGainOnRealAudio() {
        // Uncalibrated: quiet input may exceed the anchor by at most 4 dB.
        let bands = uniformBands(g65: 6, cr: 2.5)
        let g = steadyGainDB(makeProcessor(bands: bands, calibrated: false),
                             frequency: 1000, amplitude: amplitude(forSPL: 45))
        #expect(g <= 6 + P.reducedMaxExtraDB + 1.5, "measured \(g) dB")
    }

    // MARK: - Ballistics

    @Test func gainDucksQuicklyWhenLoudContentArrives() {
        // Quiet passage (high gain) → sudden loud content: the attack path
        // (5 ms detector + 8 ms smoother) must pull the gain down to near
        // its loud-level target within ~100 ms.
        let bands = uniformBands(g65: 8, cr: 2)
        let p = makeProcessor(bands: bands)
        let total = 24_000   // 0.5 s
        let loudFrom = 12_000
        let quietAmp = amplitude(forSPL: 50)
        let loudAmp = amplitude(forSPL: 90)
        var samples = [Float](repeating: 0, count: total)
        for i in 0..<total {
            let amp = i < loudFrom ? quietAmp : loudAmp
            samples[i] = Float(amp * sin(2 * Double.pi * 1000 * Double(i) / sampleRate))
        }
        samples.withUnsafeMutableBufferPointer { buf in
            var i = 0
            while i < total {
                let chunk = min(1024, total - i)
                p.process(buf.baseAddress! + i, frameCount: chunk)
                i += chunk
            }
        }
        // Gain over the loud tail (last 0.1 s) ≈ the loud-level target…
        let tail = samples.suffix(4800)
        let tailRMS = sqrt(tail.reduce(0.0) { $0 + Double($1) * Double($1) } / 4800)
        let tailGain = 20 * log10(tailRMS / (loudAmp / 2.0.squareRoot()))
        // …which for 90 SPL (≥ kneeHigh) is g65 − 12.5 clamped ≥ 0 → 0-ish.
        #expect(tailGain < 2.0, "tail gain \(tailGain) dB")
        // And the window right after the step (10–110 ms in) must already
        // be well below the quiet-passage gain (≈ 15.0 dB) — the attack is
        // doing its job long before steady state.
        let post = Array(samples[(loudFrom + 480)..<(loudFrom + 5280)])
        let postRMS = sqrt(post.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(post.count))
        let postGain = 20 * log10(postRMS / (loudAmp / 2.0.squareRoot()))
        #expect(postGain < 8, "post-step gain \(postGain) dB")
    }

    // MARK: - Stability

    @Test func burstTortureStaysFiniteAndBounded() {
        // Square-wave-ish bursts straddling the knee at high strength —
        // the §8 stability check. Every output sample finite and inside
        // a sane bound.
        let p = makeProcessor(bands: uniformBands(g65: 15, cr: 2.5))
        let total = 96_000   // 2 s
        var samples = [Float](repeating: 0, count: total)
        for i in 0..<total {
            let burstOn = (i / 2400) % 2 == 0   // 50 ms on/off
            let amp = burstOn ? amplitude(forSPL: 95) : amplitude(forSPL: 35)
            samples[i] = Float(amp * sin(2 * Double.pi * 2000 * Double(i) / sampleRate))
        }
        samples.withUnsafeMutableBufferPointer { buf in
            var i = 0
            while i < total {
                let chunk = min(1024, total - i)
                p.process(buf.baseAddress! + i, frameCount: chunk)
                i += chunk
            }
        }
        #expect(samples.allSatisfy { $0.isFinite })
        // Peak bound: max input (95 SPL → −2 dBFS peak) + absolute cap.
        let maxAllowed = Float(pow(10.0, (-2.0 + Double(P.absoluteCapDB)) / 20.0))
        #expect(samples.allSatisfy { abs($0) <= maxAllowed })
    }

    // MARK: - Telemetry

    @Test func countersReportTheAppliedGain() {
        let p = makeProcessor(bands: uniformBands(g65: 8, cr: 2))
        _ = steadyMultiToneGainDB(p, bandSPL: 65)
        // After a steady moderate passage, band 2 (1 kHz) sits at ≈ +8 dB.
        let milli = p.currentGainMilliDB(band: 2)
        #expect(abs(Double(milli) / 1000.0 - 8) < 1.5, "counter \(milli) m dB")
    }

    // MARK: - Reset semantics

    @Test func sampleRateChangeResetsCleanly() {
        let p = makeProcessor(bands: uniformBands(g65: 8, cr: 2))
        _ = steadyGainDB(p, frequency: 1000, amplitude: amplitude(forSPL: 50))
        p.setSampleRate(44_100)
        // Silence in → silence out after the reset (no stale filter state).
        var silence = [Float](repeating: 0, count: 4096)
        silence.withUnsafeMutableBufferPointer { buf in
            p.process(buf.baseAddress!, frameCount: 4096)
        }
        #expect(silence.allSatisfy { $0 == 0 })
    }

    @Test func unbypassResumesFromAnchorNotStaleState() {
        // Quiet passage drives gain up; bypass; un-bypass — the cold-start
        // envelope assumes reference level, so the first gains equal the
        // anchor (no lingering high-gain state).
        let p = makeProcessor(bands: uniformBands(g65: 8, cr: 2))
        _ = steadyGainDB(p, frequency: 1000, amplitude: amplitude(forSPL: 45))
        p.setBypassed(true)
        p.setBypassed(false)
        var burst = [Float](repeating: 0, count: 256)
        for i in 0..<256 {
            burst[i] = Float(amplitude(forSPL: 65) * sin(2 * Double.pi * 1000 * Double(i) / sampleRate))
        }
        burst.withUnsafeMutableBufferPointer { buf in
            p.process(buf.baseAddress!, frameCount: 256)
        }
        let milli = p.currentGainMilliDB(band: 2)
        #expect(abs(Double(milli) / 1000.0 - 8) < 1.0, "first-buffer gain \(milli) m dB")
    }
}
