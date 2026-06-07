import Foundation

/// Pure-math computation of biquad filter frequency responses, used by the
/// parametric canvas to draw the composite curve before any audio actually
/// flows. Coefficient formulas live in `BiquadCoefficients` so the curve
/// can't drift away from what the audio path computes.
///
/// Display sample rate defaults to 48 kHz — the curve we draw only needs to
/// match what the user *sees*; the actual engine rate may differ but in
/// practice the visual response is virtually identical at audio rates.
enum BiquadResponse {

    /// Composite magnitude response in dB at a given frequency, summing
    /// every enabled band in the chain.
    static func compositeMagnitudeDB(
        at frequencyHz: Double,
        bands: [EQBand],
        sampleRate: Double = 48_000
    ) -> Double {
        bands
            .filter { $0.enabled }
            .reduce(0.0) { sum, band in
                sum + magnitudeDB(at: frequencyHz, band: band, sampleRate: sampleRate)
            }
    }

    /// Per-band magnitude response in dB.
    static func magnitudeDB(
        at frequencyHz: Double,
        band: EQBand,
        sampleRate: Double = 48_000
    ) -> Double {
        let c = BiquadCoefficients.cookbook(for: band, sampleRate: sampleRate)
        let w = 2.0 * .pi * frequencyHz / sampleRate
        let mag = magnitude(coefficients: c, w: w)
        // log10 of zero blows up — clamp.
        return 20.0 * log10(max(mag, 1e-9))
    }

    /// |H(e^jw)| for biquad transfer H(z) = (b0+b1z⁻¹+b2z⁻²)/(a0+a1z⁻¹+a2z⁻²).
    private static func magnitude(coefficients c: BiquadCoefficients, w: Double) -> Double {
        let cosW = cos(w)
        let sinW = sin(w)
        let cos2W = cos(2.0 * w)
        let sin2W = sin(2.0 * w)

        let numRe = c.b0 + c.b1 * cosW + c.b2 * cos2W
        let numIm = -(c.b1 * sinW + c.b2 * sin2W)
        let denRe = c.a0 + c.a1 * cosW + c.a2 * cos2W
        let denIm = -(c.a1 * sinW + c.a2 * sin2W)

        let numMag = (numRe * numRe + numIm * numIm).squareRoot()
        let denMag = max(1e-12, (denRe * denRe + denIm * denIm).squareRoot())
        return numMag / denMag
    }
}
