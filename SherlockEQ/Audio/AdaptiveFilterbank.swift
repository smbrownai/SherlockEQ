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
    // LR4 high = 2 identical Butterworth-2 HP sections. Shapes are fixed
    // at init; `configure` rewrites coefficient VALUES in place and never
    // reallocates — belt-and-braces for the step-2 processor's contract
    // that sample-rate changes only happen while the render block isn't
    // running.
    private var lowSections: [[Section]] = []   // [crossover][2]
    private var highSections: [[Section]] = []  // [crossover][2]
    /// Compensation allpasses: band b (finalized at stage b, clamped to
    /// the last stage) needs one 2nd-order allpass per LATER crossover.
    /// `compensation[b][i]` is the allpass for crossover `b + 1 + i`
    /// (band 5 shares stage 4 with band 4 and needs none).
    private var compensation: [[Section]] = []
    /// Per-band scratch for the current sample's band values.
    private var bandSample = [Float](repeating: 0, count: AdaptiveFilterbank.bandCount)
    /// Scratch for the ramped-gain variant (per-sample per-band gain).
    private var gainNow = [Float](repeating: 1, count: AdaptiveFilterbank.bandCount)
    private var gainStep = [Float](repeating: 0, count: AdaptiveFilterbank.bandCount)

    private(set) var sampleRate: Double = 0

    init(sampleRate: Double = 48_000) {
        // Build the fixed structure once; `configure` only rewrites values.
        for _ in Self.crossoverHz {
            lowSections.append([Section(), Section()])
            highSections.append([Section(), Section()])
        }
        for band in 0..<Self.bandCount {
            let laterCount = band == Self.bandCount - 1
                ? 0
                : Self.crossoverHz.count - min(band + 1, Self.crossoverHz.count)
            compensation.append([Section](repeating: Section(), count: laterCount))
        }
        configure(sampleRate: sampleRate)
    }

    /// (Re)compute all coefficients for a sample rate and clear state.
    /// Main-thread only, and only while the render block isn't running
    /// (engine rebuild) — writes values in place, allocates nothing.
    func configure(sampleRate: Double) {
        self.sampleRate = sampleRate

        var allpassPrototypes: [Section] = []
        for (k, fc) in Self.crossoverHz.enumerated() {
            let (lp, hp, ap) = Self.crossoverSections(fc: fc, sampleRate: sampleRate)
            lowSections[k][0] = lp; lowSections[k][1] = lp
            highSections[k][0] = hp; highSections[k][1] = hp
            allpassPrototypes.append(ap)
        }
        for band in 0..<Self.bandCount {
            let firstLater = min(band + 1, Self.crossoverHz.count)
            for (i, s) in compensation[band].indices.enumerated() {
                compensation[band][s] = allpassPrototypes[firstLater + i]
            }
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

    /// Split → gain → sum, in place, mono, static gains. Convenience over
    /// the ramped variant below (start == end, no level measurement).
    func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int, gainsLinear: [Float]) {
        process(samples, frameCount: frameCount,
                gainsStartLinear: gainsLinear, gainsEndLinear: gainsLinear,
                bandMeanSquares: nil)
    }

    /// The step-2 processor's workhorse: split → (measure) → ramped gain →
    /// sum, in place, mono, allocation-free.
    ///
    /// - Per-band gain ramps linearly from `gainsStartLinear` to
    ///   `gainsEndLinear` across the call — the caller updates gains at
    ///   block rate and this ramp makes each step zipper-free.
    /// - `bandMeanSquares` (6 floats), when non-nil, receives each band's
    ///   PRE-GAIN mean square over the call — the feed-forward detector
    ///   input (the estimated at-ear level, before correction is applied).
    func process(
        _ samples: UnsafeMutablePointer<Float>,
        frameCount: Int,
        gainsStartLinear: [Float],
        gainsEndLinear: [Float],
        bandMeanSquares: UnsafeMutablePointer<Float>?
    ) {
        guard frameCount > 0,
              gainsStartLinear.count == Self.bandCount,
              gainsEndLinear.count == Self.bandCount else { return }
        let stages = Self.crossoverHz.count
        let invFrames = 1.0 / Float(frameCount)

        for b in 0..<Self.bandCount {
            gainNow[b] = gainsStartLinear[b]
            gainStep[b] = (gainsEndLinear[b] - gainsStartLinear[b]) * invFrames
            bandMeanSquares?[b] = 0
        }

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

            // Phase compensation + measurement + ramped gain + sum.
            var sum: Float = 0
            for b in 0..<Self.bandCount {
                var v = bandSample[b]
                for s in compensation[b].indices {
                    v = compensation[b][s].step(v)
                }
                if let out = bandMeanSquares { out[b] += v * v * invFrames }
                gainNow[b] += gainStep[b]
                sum += gainNow[b] * v
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

// MARK: - Drawing-side twin (spec §6.2: drawn = heard, extended)

extension AdaptiveFilterbank {

    /// The exact complex composite response of the compensated cascade at
    /// `hz` for the given per-band gains (dB) — pure math mirroring
    /// `process`'s topology section for section, so previews and the live
    /// overlay can never disagree with the audio. A test pins this
    /// evaluator against the time-domain probe.
    static func compositeMagnitudeDB(
        atHz hz: Double,
        gainsDB: [Double],
        sampleRate: Double
    ) -> Double {
        guard gainsDB.count == bandCount, sampleRate > 0, hz > 0 else { return 0 }
        let w = 2 * Double.pi * min(hz, sampleRate * 0.499) / sampleRate
        // z⁻¹ = e^{−jω}
        let z1 = Complex(re: cos(w), im: -sin(w))
        let z2 = z1 * z1

        func response(_ s: Section) -> Complex {
            let num = Complex(re: Double(s.b0), im: 0)
                + Complex(re: Double(s.b1), im: 0) * z1
                + Complex(re: Double(s.b2), im: 0) * z2
            let den = Complex(re: 1, im: 0)
                + Complex(re: Double(s.a1), im: 0) * z1
                + Complex(re: Double(s.a2), im: 0) * z2
            return num / den
        }

        // Per-crossover responses (LR4 = the Butterworth-2 section squared).
        var lp4: [Complex] = []
        var hp4: [Complex] = []
        var ap2: [Complex] = []
        for fc in crossoverHz {
            let (lp, hp, ap) = crossoverSections(fc: fc, sampleRate: sampleRate)
            let lpR = response(lp), hpR = response(hp)
            lp4.append(lpR * lpR)
            hp4.append(hpR * hpR)
            ap2.append(response(ap))
        }

        // Band b's path — exactly `process`'s: HP⁴ of stages 0..<b, then
        // LP⁴ of stage b (except the top band, which IS the remainder),
        // then the compensation allpasses of every later crossover.
        var sum = Complex(re: 0, im: 0)
        let stages = crossoverHz.count
        for b in 0..<bandCount {
            var path = Complex(re: 1, im: 0)
            for k in 0..<min(b, stages) { path = path * hp4[k] }
            if b < stages { path = path * lp4[b] }
            let firstLater = min(b + 1, stages)
            if b < bandCount - 1 {
                for c in firstLater..<stages { path = path * ap2[c] }
            }
            let gain = pow(10.0, gainsDB[b] / 20.0)
            sum = sum + path * Complex(re: gain, im: 0)
        }
        return 20 * log10(max(sum.magnitude, 1e-12))
    }

    private struct Complex {
        var re: Double
        var im: Double
        var magnitude: Double { (re * re + im * im).squareRoot() }
        static func + (a: Complex, b: Complex) -> Complex {
            Complex(re: a.re + b.re, im: a.im + b.im)
        }
        static func * (a: Complex, b: Complex) -> Complex {
            Complex(re: a.re * b.re - a.im * b.im, im: a.re * b.im + a.im * b.re)
        }
        static func / (a: Complex, b: Complex) -> Complex {
            let d = b.re * b.re + b.im * b.im
            return Complex(re: (a.re * b.re + a.im * b.im) / d,
                           im: (a.im * b.re - a.re * b.im) / d)
        }
    }
}
