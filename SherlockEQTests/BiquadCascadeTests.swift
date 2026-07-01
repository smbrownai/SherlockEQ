//
//  BiquadCascadeTests.swift
//  SherlockEQTests
//
//  Parity + benchmark for the vDSP-backed BiquadCascade. The production
//  cascade now runs on Accelerate's vDSP_biquad (Direct Form II); this test
//  pins its output against a scalar Direct-Form-II-transposed reference (the
//  prior hand-rolled implementation) so the swap is provably equivalent, and
//  times both so the CPU trade-off is measured rather than assumed.
//

import Testing
import Foundation
import Accelerate
@testable import SherlockEQ

@MainActor
struct BiquadCascadeTests {

    // MARK: - Scalar reference (the prior Direct-Form-II-transposed loop)

    /// Mirrors the old BiquadCascade math exactly so we can diff against it.
    /// Single channel, in-place, same identity-skipping and pre-gain fold.
    private struct ScalarReference {
        struct Section { var b0, b1, b2, a1, a2: Float }
        var sections: [Section] = []
        var preGain: Float = 1
        var z1: [Float] = []
        var z2: [Float] = []

        init(bands: [EQBand], preampDB: Double, sampleRate: Double) {
            for band in bands {
                guard let c = Self.section(for: band, sampleRate: sampleRate) else { continue }
                sections.append(c)
            }
            preGain = Float(pow(10.0, preampDB / 20.0))
            z1 = Array(repeating: 0, count: sections.count)
            z2 = Array(repeating: 0, count: sections.count)
        }

        static func section(for band: EQBand, sampleRate: Double) -> Section? {
            if !band.enabled { return nil }
            let isShape = band.filterType == .notch || band.filterType == .bandPass
                || band.filterType == .lowPass || band.filterType == .highPass
            if !isShape, band.gaindB == 0 { return nil }
            let c = BiquadCoefficients.cookbook(for: band, sampleRate: sampleRate)
            guard c.a0 != 0 else { return nil }
            return Section(b0: Float(c.b0 / c.a0), b1: Float(c.b1 / c.a0),
                           b2: Float(c.b2 / c.a0), a1: Float(c.a1 / c.a0),
                           a2: Float(c.a2 / c.a0))
        }

        mutating func process(_ samples: inout [Float]) {
            let n = sections.count
            for i in samples.indices {
                var x = samples[i] * preGain
                for k in 0..<n {
                    let s = sections[k]
                    let y = s.b0 * x + z1[k]
                    z1[k] = s.b1 * x - s.a1 * y + z2[k]
                    z2[k] = s.b2 * x - s.a2 * y
                    x = y
                }
                samples[i] = x
            }
        }
    }

    // MARK: - Fixtures

    /// Deterministic pseudo-random signal in [-1, 1] via a small LCG, so the
    /// test never flakes on RNG and both paths see identical input.
    private static func noise(count: Int, seed: UInt64 = 0x9E3779B97F4A7C15) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float(state >> 40) / Float(1 << 24)   // [0,1)
            return unit * 2 - 1
        }
    }

    /// A representative chain: two parametric peaks, a low shelf, a high shelf,
    /// and a notch — the kind of mix AutoEQ + profile + tinnitus notch produce.
    private static let representativeBands: [EQBand] = [
        EQBand(frequencyHz: 120,  gaindB: 4,  bandwidth: 0.7, filterType: .lowShelf,   enabled: true),
        EQBand(frequencyHz: 1000, gaindB: -3, bandwidth: 1.4, filterType: .parametric, enabled: true),
        EQBand(frequencyHz: 3200, gaindB: 5,  bandwidth: 2.0, filterType: .parametric, enabled: true),
        EQBand(frequencyHz: 6000, gaindB: 0,  bandwidth: 6.0, filterType: .notch,      enabled: true),
        EQBand(frequencyHz: 9000, gaindB: 3,  bandwidth: 0.7, filterType: .highShelf,  enabled: true),
    ]

    private static let sampleRate = 48_000.0

    // MARK: - Parity

    @Test func matchesScalarReferenceOverNoise() {
        let input = Self.noise(count: 4096)

        let cascade = BiquadCascade()
        cascade.setBands(Self.representativeBands, preampDB: -1.5, sampleRate: Self.sampleRate)
        var vdsp = input
        vdsp.withUnsafeMutableBufferPointer { buf in
            cascade.process(samples: buf.baseAddress!, count: buf.count)
        }

        var ref = ScalarReference(bands: Self.representativeBands, preampDB: -1.5, sampleRate: Self.sampleRate)
        var scalar = input
        ref.process(&scalar)

        var maxAbsDiff: Float = 0
        for i in vdsp.indices { maxAbsDiff = max(maxAbsDiff, abs(vdsp[i] - scalar[i])) }
        // Direct Form II vs II-transposed differ only in float rounding; on a
        // stable cascade that stays far below audible (and far below 1 LSB of
        // 16-bit, ~3e-5). Allow generous headroom for transient accumulation.
        #expect(maxAbsDiff < 1e-3, "vDSP cascade diverged from scalar reference: \(maxAbsDiff)")
    }

    @Test func steadyStateGainMatchesDrawnResponse() {
        // Feed a pure tone; the cascade's steady-state output amplitude should
        // match the composite magnitude BiquadResponse draws (the curve the
        // user sees), confirming audio and visualization agree.
        let hz = 3200.0
        let n = 8192
        let tone: [Float] = (0..<n).map { Float(sin(2 * .pi * hz * Double($0) / Self.sampleRate)) }

        let cascade = BiquadCascade()
        cascade.setBands(Self.representativeBands, preampDB: 0, sampleRate: Self.sampleRate)
        var out = tone
        out.withUnsafeMutableBufferPointer { buf in
            cascade.process(samples: buf.baseAddress!, count: buf.count)
        }

        // Peak amplitude over the settled tail (skip the filter's onset).
        let tail = out[(n / 2)...]
        let measuredPeak = tail.map(abs).max() ?? 0
        let measuredDB = 20 * log10(Double(measuredPeak))   // input peak ≈ 1 → 0 dBFS

        let expectedDB = BiquadResponse.compositeMagnitudeDB(at: hz, bands: Self.representativeBands)
        #expect(abs(measuredDB - expectedDB) < 0.5,
                "measured \(measuredDB) dB vs drawn \(expectedDB) dB")
    }

    @Test func zeroBandsIsPureGain() {
        let cascade = BiquadCascade()
        cascade.setBands([], preampDB: -6, sampleRate: Self.sampleRate)
        var buf: [Float] = [1, 1, 1, 1]
        buf.withUnsafeMutableBufferPointer { p in
            cascade.process(samples: p.baseAddress!, count: p.count)
        }
        let expected = Float(pow(10.0, -6.0 / 20.0))
        #expect(buf.allSatisfy { abs($0 - expected) < 1e-6 })
    }

    @Test func extremePreampIsClampedInCascade() {
        // Defense-in-depth: even if an unclamped value ever reached setBands
        // directly (bypassing the parser-level clamp), the cascade itself
        // must not let it through as an unbounded raw-sample multiplier.
        let cascade = BiquadCascade()
        cascade.setBands([], preampDB: 1000, sampleRate: Self.sampleRate)
        var buf: [Float] = [1, 1, 1, 1]
        buf.withUnsafeMutableBufferPointer { p in
            cascade.process(samples: p.baseAddress!, count: p.count)
        }
        let expected = Float(pow(10.0, BiquadCoefficients.gainClampDB / 20.0))
        #expect(buf.allSatisfy { abs($0 - expected) < 1e-3 })
    }

    @Test func nonFinitePreampInCascadeFallsBackToUnityGain() {
        let cascade = BiquadCascade()
        cascade.setBands([], preampDB: .nan, sampleRate: Self.sampleRate)
        var buf: [Float] = [1, 1, 1, 1]
        buf.withUnsafeMutableBufferPointer { p in
            cascade.process(samples: p.baseAddress!, count: p.count)
        }
        #expect(buf.allSatisfy { $0 == 1 })
    }

    @Test func bypassPassesThrough() {
        let cascade = BiquadCascade()
        cascade.setBands(Self.representativeBands, preampDB: -3, sampleRate: Self.sampleRate)
        cascade.setBypassed(true)
        let input: [Float] = [0.5, -0.5, 0.25, -0.25]
        var buf = input
        buf.withUnsafeMutableBufferPointer { p in
            cascade.process(samples: p.baseAddress!, count: p.count)
        }
        #expect(buf == input)   // bypass must not even apply pre-gain
    }

    @Test func sectionCountChangeClearsState() {
        // Reconfiguring to a different cascade shape must not leak delay state.
        // Process noise, swap to a single band, and confirm output is finite
        // and matches a fresh cascade configured the same way.
        let cascade = BiquadCascade()
        cascade.setBands(Self.representativeBands, preampDB: 0, sampleRate: Self.sampleRate)
        var warm = Self.noise(count: 1024)
        warm.withUnsafeMutableBufferPointer { cascade.process(samples: $0.baseAddress!, count: $0.count) }

        let single = [EQBand(frequencyHz: 1000, gaindB: 6, bandwidth: 1, filterType: .parametric, enabled: true)]
        cascade.setBands(single, preampDB: 0, sampleRate: Self.sampleRate)
        var afterSwap = Self.noise(count: 1024, seed: 0xDEADBEEF)
        afterSwap.withUnsafeMutableBufferPointer { cascade.process(samples: $0.baseAddress!, count: $0.count) }

        let fresh = BiquadCascade()
        fresh.setBands(single, preampDB: 0, sampleRate: Self.sampleRate)
        var freshOut = Self.noise(count: 1024, seed: 0xDEADBEEF)
        freshOut.withUnsafeMutableBufferPointer { fresh.process(samples: $0.baseAddress!, count: $0.count) }

        #expect(afterSwap.allSatisfy { $0.isFinite })
        var maxDiff: Float = 0
        for i in afterSwap.indices { maxDiff = max(maxDiff, abs(afterSwap[i] - freshOut[i])) }
        #expect(maxDiff < 1e-4, "delay state leaked across section-count change: \(maxDiff)")
    }

    // MARK: - Benchmark (informational, not a hard assertion)

    @Test func benchmarkVDSPvsScalar() {
        let bufferSize = 512
        let iterations = 5_000   // ~53 s of audio at 48 kHz / 512-frame buffers
        let input = Self.noise(count: bufferSize)

        let cascade = BiquadCascade()
        cascade.setBands(Self.representativeBands, preampDB: -1.5, sampleRate: Self.sampleRate)
        let vdspClock = ContinuousClock().measure {
            for _ in 0..<iterations {
                var buf = input
                buf.withUnsafeMutableBufferPointer {
                    cascade.process(samples: $0.baseAddress!, count: $0.count)
                }
                blackHole(buf)
            }
        }

        var ref = ScalarReference(bands: Self.representativeBands, preampDB: -1.5, sampleRate: Self.sampleRate)
        let scalarClock = ContinuousClock().measure {
            for _ in 0..<iterations {
                var buf = input
                ref.process(&buf)
                blackHole(buf)
            }
        }

        let vd = Double(vdspClock.components.attoseconds) / 1e18 + Double(vdspClock.components.seconds)
        let sc = Double(scalarClock.components.attoseconds) / 1e18 + Double(scalarClock.components.seconds)
        print("BiquadCascade benchmark (\(iterations)×\(bufferSize) frames, \(Self.representativeBands.count)-band):")
        print(String(format: "  vDSP_biquad : %.4f s", vd))
        print(String(format: "  scalar DF2T : %.4f s", sc))
        print(String(format: "  speedup     : %.2f×", sc / vd))

        // No hard perf assertion (CI timing is noisy); just guard against a
        // pathological regression so a broken swap can't pass silently.
        #expect(vd < sc * 5, "vDSP path unexpectedly far slower than scalar")
    }

    /// Prevent the optimizer from eliding the processed buffer.
    private func blackHole<T>(_ value: T) {
        withExtendedLifetime(value) {}
    }
}
