import Foundation

/// Pure-math computation of biquad filter frequency responses, used by the
/// parametric canvas to draw the composite curve before any audio actually
/// flows. Coefficient formulas follow Robert Bristow-Johnson's Audio EQ
/// Cookbook (the same set AVAudioUnitEQ uses internally).
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
        let coefficients = coefficients(for: band, sampleRate: sampleRate)
        let w = 2.0 * .pi * frequencyHz / sampleRate
        let mag = magnitude(coefficients: coefficients, w: w)
        // log10 of zero blows up — clamp.
        return 20.0 * log10(max(mag, 1e-9))
    }

    // MARK: - Internals

    private struct Coefficients {
        var b0, b1, b2: Double
        var a0, a1, a2: Double
    }

    /// Audio EQ Cookbook coefficients. Bandwidth is interpreted as Q for
    /// parametric / notch (the model AVAudioUnitEQ uses) and as the shelf
    /// slope `S` for low/high shelf.
    private static func coefficients(for band: EQBand, sampleRate: Double) -> Coefficients {
        let f0 = max(20.0, min(sampleRate / 2 - 1, band.frequencyHz))
        let A = pow(10.0, band.gaindB / 40.0)
        let w0 = 2.0 * .pi * f0 / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let Q = max(0.1, band.bandwidth)
        let alpha = sinW0 / (2.0 * Q)
        let sqrtA = A.squareRoot()
        let twoSqrtAalpha = 2.0 * sqrtA * alpha

        switch band.filterType {
        case .parametric:
            return Coefficients(
                b0: 1.0 + alpha * A,
                b1: -2.0 * cosW0,
                b2: 1.0 - alpha * A,
                a0: 1.0 + alpha / A,
                a1: -2.0 * cosW0,
                a2: 1.0 - alpha / A
            )
        case .lowShelf:
            return Coefficients(
                b0: A * ((A + 1) - (A - 1) * cosW0 + twoSqrtAalpha),
                b1: 2.0 * A * ((A - 1) - (A + 1) * cosW0),
                b2: A * ((A + 1) - (A - 1) * cosW0 - twoSqrtAalpha),
                a0: (A + 1) + (A - 1) * cosW0 + twoSqrtAalpha,
                a1: -2.0 * ((A - 1) + (A + 1) * cosW0),
                a2: (A + 1) + (A - 1) * cosW0 - twoSqrtAalpha
            )
        case .highShelf:
            return Coefficients(
                b0: A * ((A + 1) + (A - 1) * cosW0 + twoSqrtAalpha),
                b1: -2.0 * A * ((A - 1) + (A + 1) * cosW0),
                b2: A * ((A + 1) + (A - 1) * cosW0 - twoSqrtAalpha),
                a0: (A + 1) - (A - 1) * cosW0 + twoSqrtAalpha,
                a1: 2.0 * ((A - 1) - (A + 1) * cosW0),
                a2: (A + 1) - (A - 1) * cosW0 - twoSqrtAalpha
            )
        case .notch:
            return Coefficients(
                b0: 1.0,
                b1: -2.0 * cosW0,
                b2: 1.0,
                a0: 1.0 + alpha,
                a1: -2.0 * cosW0,
                a2: 1.0 - alpha
            )
        case .bandPass:
            // Constant-skirt band-pass (peak gain = Q). Matches AVAudioUnitEQ's
            // .bandPass mode so the curve we draw matches the audio.
            return Coefficients(
                b0: alpha,
                b1: 0,
                b2: -alpha,
                a0: 1.0 + alpha,
                a1: -2.0 * cosW0,
                a2: 1.0 - alpha
            )
        case .lowPass:
            return Coefficients(
                b0: (1.0 - cosW0) / 2.0,
                b1: 1.0 - cosW0,
                b2: (1.0 - cosW0) / 2.0,
                a0: 1.0 + alpha,
                a1: -2.0 * cosW0,
                a2: 1.0 - alpha
            )
        case .highPass:
            return Coefficients(
                b0: (1.0 + cosW0) / 2.0,
                b1: -(1.0 + cosW0),
                b2: (1.0 + cosW0) / 2.0,
                a0: 1.0 + alpha,
                a1: -2.0 * cosW0,
                a2: 1.0 - alpha
            )
        }
    }

    /// |H(e^jw)| for biquad transfer H(z) = (b0+b1z⁻¹+b2z⁻²)/(a0+a1z⁻¹+a2z⁻²).
    private static func magnitude(coefficients c: Coefficients, w: Double) -> Double {
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
