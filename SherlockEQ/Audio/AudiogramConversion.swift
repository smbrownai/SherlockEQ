import Foundation
import OSLog

/// Converts an audiogram (per-frequency hearing thresholds in dB HL) into the
/// per-ear `EQBand` chain.
///
/// **Prescription — NAL-R** (National Acoustic Laboratories, Revised; Byrne &
/// Dillon, 1986). Real-ear insertion gain per frequency:
///
///     REIG(f) = X + 0.31 · HTL(f) + k(f)
///     X       = 0.05 · (HTL₅₀₀ + HTL₁₀₀₀ + HTL₂₀₀₀)     // 3-frequency tilt term
///     k(f)    = published per-frequency constants (`nalrConstants`)
///
/// This replaces the earlier half-gain heuristic (`gain = HTL × 0.5`). NAL-R is
/// frequency-aware and grounded in audiology; it can prescribe a mild low-
/// frequency *cut* (k(250) = −17) where boosting would only muddy speech.
/// `compensationFactor` (0.25–1.0) scales the whole prescription — a strength
/// knob, not part of NAL-R.
///
/// **Why not ISO 226 (dB HL → dB SPL)?** dB HL is already normalised per
/// frequency (0 dB HL = normal threshold at that frequency), so deriving gain
/// from absolute SPL would re-introduce the ear's own frequency response and
/// boost the lows even for flat/normal hearing. NAL-R operates on the loss
/// (dB HL) directly, which is the correct quantity to compensate.
///
/// **Overlap fit.** The chain sums peaking biquads in dB (`BiquadResponse`),
/// and the audiogram's high points (3/4/6/8 kHz) sit under an octave apart, so
/// naive per-point gains over-boost where adjacent bells overlap. We run a
/// damped fixed-point solve so the *realised* composite curve lands on the
/// REIG target at each measured frequency (a peaking filter's gain at its own
/// centre equals its `gaindB`, so the fixed point is exact). Bands stay at the
/// measured audiogram frequencies — cubic-spline densification was considered
/// and deferred: with only 8 data points it adds inter-band ripple risk for
/// little benefit, and can be layered on later without changing this signature.
enum AudiogramConversion {

    /// Diagnostics for the derivation. `nonisolated` so it's callable from the
    /// nonisolated decode/derivation paths this enum runs in.
    nonisolated private static let log = Logger(
        subsystem: "com.shawnbrown.SherlockEQ", category: "Audiogram"
    )

    /// Maximum boost (or cut) any single band can carry, regardless of measured
    /// loss — guards against runaway gain from unusual audiograms or typos.
    static let perBandCeilingDB: Double = 20.0

    /// Threshold (dB HL) below which a frequency is "fine" and contributes no
    /// correction, so normal hearing yields a flat, inactive chain.
    private static let minimumActionableLossDB: Double = 5.0

    /// Q for the derived parametric bands (unchanged from the prior model).
    private static let bandQ: Double = 1.0

    /// Below this |gain|, a band is left disabled to keep the chain inert.
    private static let minimumActionableGainDB: Double = 0.25

    /// NAL-R k(f) constants (dB) — Byrne & Dillon, 1986. Interpolated in
    /// log-frequency between table points.
    private static let nalrConstants: [(hz: Double, k: Double)] = [
        (250, -17), (500, -8), (750, -3), (1000, 1), (1500, 1),
        (2000, -1), (3000, -2), (4000, -2), (6000, -2), (8000, -2),
    ]

    /// Compute EQ bands from the audiogram thresholds.
    /// - Parameters:
    ///   - audiogram: per-frequency dB HL values (typically 8 points).
    ///   - compensationFactor: 0.25–1.0 user-controlled strength.
    /// - Returns: one parametric band per audiogram frequency (sorted), with
    ///   overlap-compensated gains; bands at negligible loss/gain are disabled.
    static func bands(
        for audiogram: [AudiogramPoint],
        compensationFactor: Double
    ) -> [EQBand] {
        let cf = max(0.0, min(1.0, compensationFactor))
        let points = audiogram.sorted { $0.frequencyHz < $1.frequencyHz }
        guard !points.isEmpty else { return [] }

        // 3-frequency tilt term from 500 / 1000 / 2000 Hz.
        let X = 0.05 * (htl(500, in: points) + htl(1000, in: points) + htl(2000, in: points))

        // REIG target per measured frequency, scaled by strength. Zeroed where
        // the loss isn't actionable so normal hearing stays flat.
        let freqs = points.map { Double($0.frequencyHz) }
        let target: [Double] = points.map { p in
            guard p.thresholddBHL >= minimumActionableLossDB else { return 0 }
            return cf * (X + 0.31 * p.thresholddBHL + nalrK(Double(p.frequencyHz)))
        }

        let gains = fitGains(target: target, freqs: freqs, q: bandQ)

        return zip(freqs, gains).map { freq, gain in
            let clamped = max(-perBandCeilingDB, min(perBandCeilingDB, gain))
            return EQBand(
                frequencyHz: freq,
                gaindB: clamped,
                bandwidth: bandQ,
                filterType: .parametric,
                enabled: abs(clamped) >= minimumActionableGainDB
            )
        }
    }

    /// Convenience: rebuild both ears' bands from their audiograms.
    static func bands(
        forBothEars left: [AudiogramPoint],
        right: [AudiogramPoint],
        compensationFactor: Double
    ) -> (left: [EQBand], right: [EQBand]) {
        (
            left: bands(for: left, compensationFactor: compensationFactor),
            right: bands(for: right, compensationFactor: compensationFactor)
        )
    }

    // MARK: - NAL-R helpers

    /// Hearing threshold (dB HL) at a frequency: the measured point if present,
    /// else log-frequency-interpolated from neighbours.
    private static func htl(_ hz: Int, in points: [AudiogramPoint]) -> Double {
        if let exact = points.first(where: { $0.frequencyHz == hz }) {
            return exact.thresholddBHL
        }
        let xs = points.map { (log10(Double($0.frequencyHz)), $0.thresholddBHL) }
        return interpolate(log10(Double(hz)), xs)
    }

    /// NAL-R k(f), log-frequency-interpolated and clamped to the table ends.
    private static func nalrK(_ hz: Double) -> Double {
        interpolate(log10(hz), nalrConstants.map { (log10($0.hz), $0.k) })
    }

    /// Piecewise-linear interpolation over (x, y) samples (sorted by x),
    /// clamped flat outside the sample range.
    private static func interpolate(_ x: Double, _ samples: [(Double, Double)]) -> Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        for i in 1..<samples.count where x <= samples[i].0 {
            let (x0, y0) = samples[i - 1]
            let (x1, y1) = samples[i]
            let frac = (x - x0) / (x1 - x0)
            return y0 + frac * (y1 - y0)
        }
        return last.1
    }

    // MARK: - Overlap fit

    /// Solve for per-band gains so the dB-summed composite hits `target` at each
    /// band centre. Damped Gauss-Seidel on the exact response: at its own centre
    /// a peaking band contributes exactly its `gaindB`, so `gᵢ = targetᵢ −
    /// Σⱼ≠ᵢ contribⱼ(fᵢ)` has the realised composite equal to the target at the
    /// fixed point. Damping keeps it stable when closely-spaced bells couple
    /// strongly. Falls back to the raw target if the solve runs away.
    private static func fitGains(target: [Double], freqs: [Double], q: Double) -> [Double] {
        let n = target.count
        guard n > 1 else { return target }
        var g = target
        let omega = 0.5
        for _ in 0..<100 {
            var maxDelta = 0.0
            for i in 0..<n {
                var others = 0.0
                for j in 0..<n where j != i {
                    others += BiquadResponse.magnitudeDB(
                        at: freqs[i],
                        band: EQBand(frequencyHz: freqs[j], gaindB: g[j],
                                     bandwidth: q, filterType: .parametric, enabled: true)
                    )
                }
                let gi = target[i] - others
                maxDelta = max(maxDelta, abs(gi - g[i]))
                g[i] = (1 - omega) * g[i] + omega * gi
            }
            if maxDelta < 0.005 { break }
        }
        let ranAway = g.contains { !$0.isFinite || abs($0) > 2 * perBandCeilingDB }
        if ranAway {
            // The overlap solve diverged, so we return the RAW NAL-R targets —
            // safe against NaN/garbage, but their un-decoupled gains can
            // over-boost by several dB where the closely-spaced high bands
            // (3/4/6/8 kHz) overlap, and each is only per-band clamped, not
            // composite clamped. Silent until now (review: highest-stakes math,
            // no observability). The gain magnitude is audiogram-derived, so
            // it's `.private`; the fact of the fallback is `.public`.
            let maxMag = g.filter(\.isFinite).map(abs).max() ?? .infinity
            log.warning("""
                Audiogram overlap-fit did not converge                 (max |gain| \(maxMag, format: .fixed(precision: 1), privacy: .private) dB);                 using raw NAL-R targets, which may over-boost where bands overlap.
                """)
        }
        return ranAway ? target : g
    }
}
