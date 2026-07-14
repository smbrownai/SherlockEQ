import Foundation

/// Fits arbitrary off-grid filters onto the Graphic surface's 12 one-octave
/// bells (phase3-make-correction-land.md §1.4) — the math behind the "Other
/// filters" row's **Convert to Graphic EQ** action.
///
/// Why a fit and not a per-point copy: the graphic bells overlap (one-octave
/// bandwidth on ⅓–1-octave spacing), so naively sampling the source response
/// at each center and assigning it as that slider's gain over-shoots wherever
/// neighbours contribute. The damped fixed-point iteration below solves for
/// slider gains whose *realised composite* lands on the target — the same
/// technique `AudiogramConversion` uses to fit the NAL-R prescription.
///
/// Fidelity limits are inherent and accepted: peaking bells can't hold a
/// shelf's plateau out to the spectrum edges or reproduce a low/high-pass
/// brick wall, and gains clamp to the slider range. The row's copy says
/// "approximates"; the user can always take the Parametric escape hatch
/// instead. Cascade magnitudes add in dB, so fitting the off-grid bands
/// alone and *adding* the result to the current slider gains is exact up to
/// the fit error itself.
enum GraphicConversion {

    /// The graphic sliders' gain range — fitted gains clamp here.
    static let sliderRangeDB: ClosedRange<Double> = -12...12

    /// Fitted gains below this snap to 0 so conversion leaves clean sliders
    /// (and no band at all) where the source had no audible contribution.
    static let zeroSnapDB: Double = 0.05

    private static let iterations = 24
    private static let damping = 0.5

    /// Gains for the 12 `EQMode.graphicCenters` bells whose composite
    /// response approximates `bands`' composite. Disabled bands contribute
    /// nothing and should be filtered by the caller. Returns all zeros for
    /// an empty input.
    static func fittedGains(for bands: [EQBand]) -> [Double] {
        let centers = EQMode.graphicCenters
        guard !bands.isEmpty else { return Array(repeating: 0, count: centers.count) }

        let targets = centers.map { BiquadResponse.compositeMagnitudeDB(at: $0, bands: bands) }
        var gains = [Double](repeating: 0, count: centers.count)

        for _ in 0..<iterations {
            let trial = trialBands(centers: centers, gains: gains)
            for i in centers.indices {
                let realised = BiquadResponse.compositeMagnitudeDB(at: centers[i], bands: trial)
                let next = gains[i] + damping * (targets[i] - realised)
                gains[i] = min(sliderRangeDB.upperBound, max(sliderRangeDB.lowerBound, next))
            }
        }

        return gains.map { abs($0) < zeroSnapDB ? 0 : $0 }
    }

    private static func trialBands(centers: [Double], gains: [Double]) -> [EQBand] {
        zip(centers, gains).map { freq, gain in
            EQBand(frequencyHz: freq, gaindB: gain, bandwidth: 1.0, filterType: .parametric, enabled: true)
        }
    }
}
