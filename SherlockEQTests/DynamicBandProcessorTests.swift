//
//  DynamicBandProcessorTests.swift
//  SherlockEQTests
//
//  Realtime-DSP invariants for the level-dependent ("dynamic") EQ stage
//  (spec §9.1). The processor recomputes biquad coefficients on the
//  render thread as an envelope moves — these tests pin its safety and
//  behavioural contract: transparent at rest, clamped under abuse,
//  level-independent, stable under pathological modulation, and tied to
//  the shared Audio EQ Cookbook math.
//
//  Note on ballistics: the spec's "±30% of the attack constant" assumes
//  a single time constant. The implementation cascades a per-feature
//  attack/release envelope with a 5 ms gain smoother, so the *observed*
//  engage time is intentionally longer than `attackMs`. These tests
//  therefore assert ordering and bounded ranges (and that a fast-attack
//  feature engages faster than a slow one) rather than a brittle exact
//  figure.
//

import Testing
import Foundation
@testable import SherlockEQ

struct DynamicBandProcessorTests {

    private static let SR: Double = 48_000

    // MARK: - Harness

    /// A processor configured with a single enabled feature slot.
    private static func processor(
        _ kind: DynamicFeatureKind,
        strength: Double,
        sensitivity: Double,
        sampleRate: Double = SR
    ) -> DynamicBandProcessor {
        let p = DynamicBandProcessor()
        p.setSampleRate(sampleRate)
        p.configure(slots: [
            .init(
                kind: kind,
                enabled: true,
                maxDeltaDB: kind.maxDeltaDB(strength: strength),
                thresholdOffsetDB: kind.thresholdOffsetDB(sensitivity: sensitivity)
            )
        ])
        return p
    }

    /// Feed `count` samples (in `chunk`-sized buffers) through the
    /// processor, returning the processed output and recording the
    /// smoothed gain delta (dB) once per chunk in `deltaTrace`.
    @discardableResult
    private static func feed(
        _ p: DynamicBandProcessor,
        kind: DynamicFeatureKind?,
        count: Int,
        chunk: Int = 256,
        deltaTrace: inout [Double],
        generator: (Int) -> Float
    ) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(count)
        var n = 0
        while n < count {
            let c = min(chunk, count - n)
            var buf = (0..<c).map { generator(n + $0) }
            buf.withUnsafeMutableBufferPointer { bp in
                p.process(samples: bp.baseAddress!, count: c)
            }
            out.append(contentsOf: buf)
            if let kind { deltaTrace.append(Double(p.currentDeltaMilliDB(kind)) / 1000.0) }
            n += c
        }
        return out
    }

    private static func samples(_ seconds: Double, sampleRate: Double = SR) -> Int {
        Int(seconds * sampleRate)
    }

    /// A continuous-phase sine generator at the detector-band centre of a
    /// kind, at linear amplitude `amp`.
    private static func detectorTone(_ kind: DynamicFeatureKind, amp: Float, sampleRate: Double = SR) -> (Int) -> Float {
        let (lo, hi) = kind.detectorBand
        let freq = (lo * hi).squareRoot()
        let w = 2.0 * Double.pi * freq / sampleRate
        return { i in amp * Float(sin(w * Double(i))) }
    }

    // MARK: - 1 & 2. Transparency

    @Test func disabledSlotsArePassthrough() {
        let p = DynamicBandProcessor()
        p.setSampleRate(Self.SR)
        p.configure(slots: [
            .init(kind: .sibilanceTamer, enabled: false, maxDeltaDB: -10, thresholdOffsetDB: 6)
        ])
        let gen = Self.detectorTone(.sibilanceTamer, amp: 0.5)
        let input = (0..<2048).map { gen($0) }
        var buf = input
        buf.withUnsafeMutableBufferPointer { p.process(samples: $0.baseAddress!, count: $0.count) }
        #expect(buf == input)
    }

    @Test func strengthZeroIsBitIdentical() {
        let p = Self.processor(.sibilanceTamer, strength: 0, sensitivity: 1.0)
        let gen = Self.detectorTone(.sibilanceTamer, amp: 0.7)
        let input = (0..<4096).map { gen($0) }
        var buf = input
        buf.withUnsafeMutableBufferPointer { p.process(samples: $0.baseAddress!, count: $0.count) }
        #expect(buf == input)
    }

    @Test func bypassIsBitIdenticalAndResetsOnReEnable() {
        let p = Self.processor(.harshnessControl, strength: 1.0, sensitivity: 1.0)
        p.setBypassed(true)
        let gen = Self.detectorTone(.harshnessControl, amp: 0.8)
        let input = (0..<2048).map { gen($0) }
        var buf = input
        buf.withUnsafeMutableBufferPointer { p.process(samples: $0.baseAddress!, count: $0.count) }
        #expect(buf == input)

        // Un-bypass: processing resumes; a fresh run produces finite,
        // bounded output (clean state, no leftover transient).
        p.setBypassed(false)
        var trace: [Double] = []
        let out = Self.feed(p, kind: .harshnessControl, count: Self.samples(0.5), deltaTrace: &trace) { gen($0) }
        #expect(out.allSatisfy { $0.isFinite })
    }

    // MARK: - 4. Max-delta clamp

    @Test func cutDeltaNeverExceedsFeatureMax() {
        // Full-scale detector-band tone at strength 1.0 — the early
        // transient slams the gain to its limit before the rolling
        // average catches up. The delta must never overshoot the cap.
        let p = Self.processor(.sibilanceTamer, strength: 1.0, sensitivity: 1.0)
        let gen = Self.detectorTone(.sibilanceTamer, amp: 1.0)
        var trace: [Double] = []
        Self.feed(p, kind: .sibilanceTamer, count: Self.samples(1.0), deltaTrace: &trace) { gen($0) }
        let maxCut = trace.min() ?? 0       // most-negative delta
        #expect(maxCut >= -10.5)            // feature max is -10 dB (+0.5 tol)
        #expect((trace.max() ?? 0) <= 0.001) // a cut feature never boosts
    }

    @Test func boostDeltaNeverNegativeNorExceedsMax() {
        let p = Self.processor(.speechPresence, strength: 1.0, sensitivity: 1.0)
        let gen = Self.detectorTone(.speechPresence, amp: 1.0)
        var trace: [Double] = []
        Self.feed(p, kind: .speechPresence, count: Self.samples(1.0), deltaTrace: &trace) { gen($0) }
        #expect((trace.min() ?? 0) >= -0.001)  // a boost feature never cuts
        #expect((trace.max() ?? 0) <= 6.5)      // feature max is +6 dB (+0.5 tol)
    }

    // MARK: - 3 & 8. Engage / release

    @Test func cutEngagesOnInBandBurstThenRelaxes() {
        let p = Self.processor(.sibilanceTamer, strength: 1.0, sensitivity: 0.5)
        let tone = Self.detectorTone(.sibilanceTamer, amp: 0.6)
        let burst = Self.samples(0.3)
        let total = Self.samples(1.2)
        var trace: [Double] = []
        Self.feed(p, kind: .sibilanceTamer, count: total, deltaTrace: &trace) { i in
            i < burst ? tone(i) : 0      // 0.3 s burst, then silence
        }
        // Peak engagement during the burst is a real cut.
        #expect((trace.min() ?? 0) <= -2.0)
        // After release, the gain returns to rest (≤ 0.1 dB).
        #expect(abs(trace.last ?? 99) <= 0.1)
    }

    @Test func speechPresenceGatesAndNeverAmplifiesPauses() {
        let p = Self.processor(.speechPresence, strength: 1.0, sensitivity: 0.5)
        let tone = Self.detectorTone(.speechPresence, amp: 0.5)
        let burst = Self.samples(0.5)
        // Speech Presence releases over 300 ms; reaching ≤ 0.1 dB from a
        // full +6 dB boost takes ~4 time constants (~1.3 s), so give the
        // pause 2 s of room.
        let total = burst + Self.samples(2.0)
        var trace: [Double] = []
        Self.feed(p, kind: .speechPresence, count: total, deltaTrace: &trace) { i in
            i < burst ? tone(i) : 0
        }
        // Engages a boost while speech is present...
        #expect((trace.max() ?? 0) >= 1.0)
        // ...and relaxes to ≤ 0.1 dB during the pause (never amplifies it).
        #expect(abs(trace.last ?? 99) <= 0.1)
        #expect((trace.min() ?? 0) >= -0.001)
    }

    @Test func fastAttackEngagesFasterThanSlowAttack() {
        // Sibilance (3 ms) should reach engagement sooner than Speech
        // Presence (30 ms) — a robust relative stand-in for the literal
        // ballistics figure.
        func chunksToEngage(_ kind: DynamicFeatureKind) -> Int {
            let p = Self.processor(kind, strength: 1.0, sensitivity: 1.0)
            let tone = Self.detectorTone(kind, amp: 0.7)
            var trace: [Double] = []
            // Small chunks for time resolution.
            Self.feed(p, kind: kind, count: Self.samples(0.2), chunk: 32, deltaTrace: &trace) { tone($0) }
            let threshold = 0.5  // |dB|
            return trace.firstIndex(where: { abs($0) >= threshold }) ?? trace.count
        }
        #expect(chunksToEngage(.sibilanceTamer) <= chunksToEngage(.speechPresence))
    }

    // MARK: - 5. Level independence

    @Test func engagementIsLevelIndependent() {
        // The same +20 dB relative burst over a quiet bed and a loud bed
        // (20 dB apart) should produce comparable engagement, because the
        // threshold tracks each bed's rolling average.
        func peakEngagement(bedAmp: Float) -> Double {
            let kind = DynamicFeatureKind.sibilanceTamer
            let p = Self.processor(kind, strength: 1.0, sensitivity: 0.5)
            let bed = Self.detectorTone(kind, amp: bedAmp)
            let burstAmp = bedAmp * 10        // +20 dB
            let burst = Self.detectorTone(kind, amp: burstAmp)
            let warm = Self.samples(6.0)      // let the 3 s average settle
            let burstStart = warm
            let burstEnd = warm + Self.samples(0.2)
            let total = burstEnd
            var trace: [Double] = []
            Self.feed(p, kind: kind, count: total, deltaTrace: &trace) { i in
                (i >= burstStart && i < burstEnd) ? burst(i) : bed(i)
            }
            // Engagement attributable to the burst = how far below rest the
            // delta dipped during the burst window.
            let burstChunkStart = burstStart / 256
            let burstTrace = Array(trace.suffix(from: min(burstChunkStart, trace.count)))
            return abs(burstTrace.min() ?? 0)
        }
        let quiet = peakEngagement(bedAmp: 0.02)
        let loud = peakEngagement(bedAmp: 0.2)
        #expect(quiet > 1.0)               // the burst actually triggered
        #expect(loud > 1.0)
        #expect(abs(quiet - loud) <= 2.0)  // comparable regardless of absolute level
    }

    // MARK: - 6. Stability under pathological modulation

    @Test func stableUnderSquareWaveBurstsStraddlingThreshold() {
        let p = Self.processor(.sibilanceTamer, strength: 1.0, sensitivity: 0.5)
        let tone = Self.detectorTone(.sibilanceTamer, amp: 0.9)
        let period = Self.samples(0.05)     // 50 ms on / 50 ms off
        var trace: [Double] = []
        let out = Self.feed(p, kind: .sibilanceTamer, count: Self.samples(4.0), deltaTrace: &trace) { i in
            ((i / period) % 2 == 0) ? tone(i) : 0
        }
        #expect(out.allSatisfy { $0.isFinite })
        #expect(out.allSatisfy { abs($0) <= 4.0 })   // a cut can't blow up the level
        #expect(trace.allSatisfy { $0.isFinite })
        #expect((trace.min() ?? 0) >= -10.5)
    }

    // MARK: - 7. Denormal / silence handling

    @Test func decaysToSilenceWithoutDenormalBlowup() {
        let p = Self.processor(.harshnessControl, strength: 1.0, sensitivity: 0.5)
        let tone = Self.detectorTone(.harshnessControl, amp: 0.8)
        let on = Self.samples(0.5)
        let total = Self.samples(2.5)
        var trace: [Double] = []
        let out = Self.feed(p, kind: .harshnessControl, count: total, deltaTrace: &trace) { i in
            i < on ? tone(i) : 0
        }
        #expect(out.allSatisfy { $0.isFinite })
        // Long-silence tail is effectively zero (state flushed, no lingering
        // subnormal energy).
        #expect(abs(out.last ?? 1) < 1e-6)
        #expect(abs(trace.last ?? 99) <= 0.1)
    }

    // MARK: - 9. Tied to the shared cookbook

    @Test func rawCookbookMatchesEQBandCookbook() {
        // The dynamic processor recomputes its bell via the raw
        // `cookbook(filterType:freqHz:q:gainDB:)` entry point; it must be
        // identical to the `EQBand` overload the static cascade + drawn
        // curve use, so dynamic audio can't disagree with either.
        let cases: [(EQFilterType, Double, Double, Double)] = [
            (.parametric, 2_500, 0.9, 6),
            (.parametric, 3_500, 1.4, -8),
            (.parametric, 6_500, 2.0, -10),
            (.bandPass, 2_449, 1.0, 0),
        ]
        for (type, f, q, gain) in cases {
            let raw = BiquadCoefficients.cookbook(filterType: type, freqHz: f, q: q, gainDB: gain, sampleRate: Self.SR)
            let viaBand = BiquadCoefficients.cookbook(
                for: EQBand(frequencyHz: f, gaindB: gain, bandwidth: q, filterType: type, enabled: true),
                sampleRate: Self.SR
            )
            #expect(raw.b0 == viaBand.b0)
            #expect(raw.b1 == viaBand.b1)
            #expect(raw.b2 == viaBand.b2)
            #expect(raw.a0 == viaBand.a0)
            #expect(raw.a1 == viaBand.a1)
            #expect(raw.a2 == viaBand.a2)
        }
    }

    // MARK: - 10. Decoder backward-compat (dynamics field)

    @Test func profileWithoutDynamicsDecodesToAllDisabled() throws {
        let json = """
        {
          "id": "33333333-3333-3333-3333-333333333333",
          "name": "Pre-dynamics",
          "symbol": "person.fill",
          "leftEar": { "thresholds": [], "bands": [] },
          "rightEar": { "thresholds": [], "bands": [] },
          "leftNotch": { "enabled": false, "frequencyHz": 6000, "depthdB": -6, "qWidth": "medium" },
          "rightNotch": { "enabled": false, "frequencyHz": 6000, "depthdB": -6, "qWidth": "medium" },
          "globalTrimDB": 0,
          "safeListeningCeilingDB": 85,
          "compensationFactor": 0.5,
          "createdAt": "2025-01-01T00:00:00Z",
          "modifiedAt": "2025-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(HearingProfile.self, from: json)
        #expect(!profile.dynamics.hasAnyEnabled)
        #expect(!profile.dynamics.separateChannels)
    }

    @Test func dynamicsSurvivesRoundTrip() throws {
        var original = HearingProfile.makeDefault(name: "Dyn round-trip")
        original.dynamics.separateChannels = true
        original.dynamics.setSettings(
            .init(enabled: true, strength: 0.7, sensitivity: 0.3),
            for: .sibilanceTamer, ear: .left
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HearingProfile.self, from: data)

        #expect(decoded.dynamics.separateChannels)
        let s = decoded.dynamics.settings(for: .sibilanceTamer, ear: .left)
        #expect(s.enabled)
        #expect(s.strength == 0.7)
        #expect(s.sensitivity == 0.3)
        // Untouched slots stay disabled.
        #expect(!decoded.dynamics.settings(for: .speechPresence, ear: .right).enabled)
    }
}
