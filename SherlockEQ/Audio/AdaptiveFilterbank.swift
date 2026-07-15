import Foundation

/// Six-band Linkwitz–Riley (LR4) filterbank with per-band scalar gains —
/// the signal-splitting half of Adaptive Correction
/// (phase4-adaptive-correction.md §2).
///
/// Architecture: a **compensated sequential cascade**. Five LR4 crossovers
/// (355 / 710 / 1400 / 2800 / 5600 Hz) peel bands off low-to-high; each
/// band then passes through the 2nd-order allpasses of every *later*
/// crossover so all six branches carry identical phase rotation. LR4's
/// defining property — LP⁴(s) + HP⁴(s) = A²(s), a 2nd-order allpass with
/// the Butterworth denominator — makes the unity-gain sum exactly allpass:
/// **flat magnitude by construction**, which §8's probe test asserts
/// rather than assumes (≤ 0.5 dB ripple, 20 Hz – 20 kHz).
///
/// The dynamic element is deliberately trivial (spec Design note 2): the
/// crossovers are STATIC filters computed once per sample rate; per-band
/// gain is a smoothed scalar multiply supplied by the caller per process
/// call. No coefficient modulation on the audio thread, and idle
/// (all-unity) output equals input to within the allpass.
///
/// Realtime rules: all state pre-allocated at init; `process` allocates
/// nothing; denormals flushed once per call at the module's established
/// threshold. Not thread-safe by itself — the step-2 processor owns one
/// per ear and serializes access from the render block.
final class AdaptiveFilterbank {

    /// Crossover frequencies. Geometric band centers ≈ 250 / 500 / 1k /
    /// 2k / 4k / 8k Hz — the audiogram octave grid (3/6 kHz detail folds
    /// in via HTL interpolation, spec §10 open-Q1).
    static let crossoverHz: [Double] = [355, 710, 1400, 2800, 5600]
    static let bandCount = 6
    /// Nominal band centers, for prescription lookup and display.
    static let bandCenters: [Double] = [250, 500, 1000, 2000, 4000, 8000]

    private static let denormalThreshold: Float = 1e-25

    /// One DF2T biquad section (same recurrence as `BiquadCascade`).
    private struct Section {
        var b0: Float = 1, b1: Float = 0, b2: Float = 0
        var a1: Float = 0, a2: Float = 0
        var z1: Float = 0, z2: Float = 0

        mutating func step(_ x: Float) -> Float {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }

        mutating func reset() { z1 = 0; z2 = 0 }

        mutating func flushDenormals() {
            if abs(z1) < AdaptiveFilterbank.denormalThreshold { z1 = 0 }
            if abs(z2) < AdaptiveFilterbank.denormalThreshold { z2 = 0 }
        }
    }

    // Per crossover k: LR4 low = 2 identical Butterworth-2 LP sections,
    // LR4 high = 2 identical Butterworth-2 HP sections.
    private var lowSections: [[Section]] = []   // [crossover][2]
    private var highSections: [[Section]] = []  // [crossover][2]
    /// Compensation allpasses: band b (finalized at stage b, clamped to
    /// the last stage) needs one 2nd-order allpass per LATER crossover.
    /// `compensation[b][i]` is the allpass for crossover `b + 1 + i`
    /// (band 5 shares stage 4 with band 4 and needs none).
    private var compensation: [[Section]] = []
    /// Per-band scratch for the current sample's band values.
    private var bandSample = [Float](repeating: 0, count: AdaptiveFilterbank.bandCount)

    private(set) var sampleRate: Double = 0

    init(sampleRate: Double = 48_000) {
        configure(sampleRate: sampleRate)
    }

    /// (Re)compute all coefficients for a sample rate and clear state.
    /// Main-thread only; the audio thread never calls this.
    func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
        lowSections = []
        highSections = []
        compensation = []

        var allpassPrototypes: [Section] = []
        for fc in Self.crossoverHz {
            let (lp, hp, ap) = Self.crossoverSections(fc: fc, sampleRate: sampleRate)
            lowSections.append([lp, lp])
            highSections.append([hp, hp])
            allpassPrototypes.append(ap)
        }

        // Band b's compensation chain: allpasses of crossovers after the
        // stage that finalized it (band index == stage index, except band
        // 5 which shares the last stage and needs none).
        for band in 0..<Self.bandCount {
            let firstLater = min(band + 1, Self.crossoverHz.count)
            let later = band == Self.bandCount - 1 ? [] : Array(allpassPrototypes[firstLater...])
            compensation.append(later)
        }
        reset()
    }

    /// Zero all filter state (SR change, enable, bypass transitions).
    func reset() {
        for k in lowSections.indices {
            for s in lowSections[k].indices { lowSections[k][s].reset() }
            for s in highSections[k].indices { highSections[k][s].reset() }
        }
        for b in compensation.indices {
            for s in compensation[b].indices { compensation[b][s].reset() }
        }
    }

    /// Split → gain → sum, in place, mono. `gainsLinear` is one linear
    /// gain per band (callers pre-smooth; this class applies them
    /// verbatim). Allocation-free.
    func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int, gainsLinear: [Float]) {
        guard frameCount > 0, gainsLinear.count == Self.bandCount else { return }
        let stages = Self.crossoverHz.count

        for i in 0..<frameCount {
            var remainder = samples[i]
            // Peel bands low → high. Band k = LR4-low of the running
            // remainder at crossover k; the remainder continues through
            // LR4-high. The final remainder is the top band.
            for k in 0..<stages {
                var low = remainder
                low = lowSections[k][0].step(low)
                low = lowSections[k][1].step(low)
                bandSample[k] = low

                var high = remainder
                high = highSections[k][0].step(high)
                high = highSections[k][1].step(high)
                remainder = high
            }
            bandSample[stages] = remainder

            // Phase compensation + gain + sum.
            var sum: Float = 0
            for b in 0..<Self.bandCount {
                var v = bandSample[b]
                for s in compensation[b].indices {
                    v = compensation[b][s].step(v)
                }
                sum += gainsLinear[b] * v
            }
            samples[i] = sum
        }

        for k in lowSections.indices {
            for s in lowSections[k].indices { lowSections[k][s].flushDenormals() }
            for s in highSections[k].indices { highSections[k][s].flushDenormals() }
        }
        for b in compensation.indices {
            for s in compensation[b].indices { compensation[b][s].flushDenormals() }
        }
    }

    // MARK: - Coefficients

    /// Butterworth-2 (Q = 1/√2) low-pass and high-pass at `fc`, plus the
    /// matching 2nd-order allpass (numerator = reversed denominator) —
    /// exactly the LR4 pair's summed phase response.
    private static func crossoverSections(
        fc: Double, sampleRate: Double
    ) -> (lp: Section, hp: Section, ap: Section) {
        let w0 = 2 * Double.pi * min(fc, sampleRate * 0.45) / sampleRate
        let cosW = cos(w0)
        let alpha = sin(w0) / (2 * (1 / 2.0.squareRoot()))
        let a0 = 1 + alpha
        let a1 = Float(-2 * cosW / a0)
        let a2 = Float((1 - alpha) / a0)

        var lp = Section()
        lp.b0 = Float((1 - cosW) / 2 / a0)
        lp.b1 = Float((1 - cosW) / a0)
        lp.b2 = lp.b0
        lp.a1 = a1
        lp.a2 = a2

        var hp = Section()
        hp.b0 = Float((1 + cosW) / 2 / a0)
        hp.b1 = Float(-(1 + cosW) / a0)
        hp.b2 = hp.b0
        hp.a1 = a1
        hp.a2 = a2

        var ap = Section()
        ap.b0 = a2
        ap.b1 = a1
        ap.b2 = 1
        ap.a1 = a1
        ap.a2 = a2

        return (lp, hp, ap)
    }
}
