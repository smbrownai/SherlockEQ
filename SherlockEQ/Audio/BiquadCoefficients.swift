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

    /// Hard limit on `gaindB` accepted into the cookbook. The UI clamps
    /// to ±12 / ±24 dB depending on view, but imported AutoEQ profiles
    /// can carry larger values. Past ~±40 dB `A` (= 10^(gain/40)) drives
    /// `a0` close to zero and the cascade can NaN-propagate forever
    /// through `z1` / `z2`. ±30 dB sits well past any musically useful
    /// range while still keeping the filter numerically stable.
    static let gainClampDB: Double = 30.0

    /// Cookbook coefficients for one EQ band. `bandwidth` is interpreted
    /// as Q (matching AVAudioUnitEQ's parametric/notch model and the
    /// shelf slope conventions used elsewhere in this codebase).
    /// `frequencyHz` is clamped to [20, Nyquist−1] and `gaindB` is clamped
    /// to ±`gainClampDB` so callers passing in out-of-range values get a
    /// stable filter rather than NaNs.
    static func cookbook(for band: EQBand, sampleRate: Double) -> BiquadCoefficients {
        cookbook(
            filterType: band.filterType,
            freqHz: band.frequencyHz,
            q: band.bandwidth,
            gainDB: band.gaindB,
            sampleRate: sampleRate
        )
    }

    /// Cookbook coefficients from raw filter parameters — no `EQBand`
    /// construction required. The render thread's `DynamicBandProcessor`
    /// calls this to recompute a modulated bell's coefficients per block
    /// without allocating (constructing an `EQBand` would mint a `UUID`),
    /// while the curve and static cascade reach the identical math via
    /// the `EQBand` overload above. Same clamping contract: `freqHz` to
    /// [20, Nyquist−1], `gainDB` to ±`gainClampDB`, `q` floored at 0.1.
    static func cookbook(
        filterType: EQFilterType,
        freqHz: Double,
        q: Double,
        gainDB: Double,
        sampleRate: Double
    ) -> BiquadCoefficients {
        let f0 = max(20.0, min(sampleRate / 2 - 1, freqHz))
        let gainDB = max(-gainClampDB, min(gainClampDB, gainDB))
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * .pi * f0 / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let Q = max(0.1, q)
        let alpha = sinW0 / (2.0 * Q)
        let sqrtA = A.squareRoot()
        let twoSqrtAalpha = 2.0 * sqrtA * alpha

        switch filterType {
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
