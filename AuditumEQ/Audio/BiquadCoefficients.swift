import Foundation

/// Audio EQ Cookbook biquad coefficients (Robert Bristow-Johnson).
/// Single source of truth for both the audio path (`BiquadCascade`)
/// and the curve drawing (`BiquadResponse`). When these were duplicated,
/// a divergence in either switch statement would silently make the EQ
/// curve disagree with what the user hears — same band, two formulas.
struct BiquadCoefficients {
    var b0: Double
    var b1: Double
    var b2: Double
    var a0: Double
    var a1: Double
    var a2: Double

    /// Cookbook coefficients for one EQ band. `bandwidth` is interpreted
    /// as Q (matching AVAudioUnitEQ's parametric/notch model and the
    /// shelf slope conventions used elsewhere in this codebase).
    /// `frequencyHz` is clamped to [20, Nyquist−1] so callers passing in
    /// out-of-range values get a stable filter rather than NaNs.
    static func cookbook(for band: EQBand, sampleRate: Double) -> BiquadCoefficients {
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
            return BiquadCoefficients(
                b0: 1 + alpha * A,
                b1: -2 * cosW0,
                b2: 1 - alpha * A,
                a0: 1 + alpha / A,
                a1: -2 * cosW0,
                a2: 1 - alpha / A
            )
        case .lowShelf:
            return BiquadCoefficients(
                b0: A * ((A + 1) - (A - 1) * cosW0 + twoSqrtAalpha),
                b1: 2 * A * ((A - 1) - (A + 1) * cosW0),
                b2: A * ((A + 1) - (A - 1) * cosW0 - twoSqrtAalpha),
                a0: (A + 1) + (A - 1) * cosW0 + twoSqrtAalpha,
                a1: -2 * ((A - 1) + (A + 1) * cosW0),
                a2: (A + 1) + (A - 1) * cosW0 - twoSqrtAalpha
            )
        case .highShelf:
            return BiquadCoefficients(
                b0: A * ((A + 1) + (A - 1) * cosW0 + twoSqrtAalpha),
                b1: -2 * A * ((A - 1) + (A + 1) * cosW0),
                b2: A * ((A + 1) + (A - 1) * cosW0 - twoSqrtAalpha),
                a0: (A + 1) - (A - 1) * cosW0 + twoSqrtAalpha,
                a1: 2 * ((A - 1) - (A + 1) * cosW0),
                a2: (A + 1) - (A - 1) * cosW0 - twoSqrtAalpha
            )
        case .notch:
            return BiquadCoefficients(
                b0: 1,
                b1: -2 * cosW0,
                b2: 1,
                a0: 1 + alpha,
                a1: -2 * cosW0,
                a2: 1 - alpha
            )
        case .bandPass:
            // Constant-skirt band-pass (peak gain = Q). Matches AVAudioUnitEQ's
            // .bandPass mode so the curve we draw matches the audio.
            return BiquadCoefficients(
                b0: alpha,
                b1: 0,
                b2: -alpha,
                a0: 1 + alpha,
                a1: -2 * cosW0,
                a2: 1 - alpha
            )
        case .lowPass:
            return BiquadCoefficients(
                b0: (1 - cosW0) / 2,
                b1: 1 - cosW0,
                b2: (1 - cosW0) / 2,
                a0: 1 + alpha,
                a1: -2 * cosW0,
                a2: 1 - alpha
            )
        case .highPass:
            return BiquadCoefficients(
                b0: (1 + cosW0) / 2,
                b1: -(1 + cosW0),
                b2: (1 + cosW0) / 2,
                a0: 1 + alpha,
                a1: -2 * cosW0,
                a2: 1 - alpha
            )
        }
    }
}
