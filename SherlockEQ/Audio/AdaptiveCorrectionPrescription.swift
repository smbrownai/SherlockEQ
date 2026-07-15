import Foundation

/// The gain rule of Adaptive Correction (phase4-adaptive-correction.md §1):
/// per-band, level-dependent insertion gain prescribed from the audiogram,
/// **anchored to NAL-R at 65 dB SPL** — at moderate speech level, Adaptive
/// equals the profile's existing Steady correction exactly; quieter inputs
/// get more gain, louder inputs less, along a loss-derived compression
/// slope.
///
/// Pure math, no state, no audio — every §7.2 safety invariant that
/// concerns *how much gain can ever be applied* is provable against this
/// type alone:
///   • gain ≤ `absoluteCapDB` for any input whatsoever,
///   • gain ≤ anchor + `maxExtraDB` (or + `reducedMaxExtraDB` when the
///     calibration was never performed — §7.3's reduced-depth mode),
///   • gain is monotonically non-increasing in input level,
///   • non-finite anything → unity (0 dB), never garbage.
///
/// Every constant lives here (the `DynamicFeatureKind` convention): tuning
/// is a one-file change, and §8's listening pass may retune ballistics and
/// knees without touching structure.
enum AdaptiveCorrectionPrescription {

    // MARK: - Constants (spec §1.1)

    /// Moderate-speech anchor: at this band input level the prescribed
    /// gain equals the NAL-R value (`g65DB`).
    static let referenceSPL: Double = 65
    /// Below this band level, gain holds constant — near-silence is not
    /// chased upward (low-level expansion is a v2 tuning option).
    static let kneeLowSPL: Double = 45
    /// Above this band level, the gain taper has fully played out.
    static let kneeHighSPL: Double = 90
    /// Adaptation may exceed the NAL-R anchor by at most this much.
    static let maxExtraDB: Double = 10
    /// §7.3 reduced-depth mode: the cap when the user never actually set
    /// the SPL calibration (default rule-of-thumb offset) — audibly
    /// adaptive, but the error budget stays a fraction of the anchor
    /// uncertainty. Not a hard block: Adaptive-lite still beats Steady.
    static let reducedMaxExtraDB: Double = 4
    /// Hard ceiling on any band's insertion gain, independent of
    /// audiogram, calibration, and strength — the last line of defense.
    static let absoluteCapDB: Double = 24
    /// Compression-ratio cap — conservative against NAL-NL2's typical
    /// range for mild-to-moderate loss.
    static let compressionRatioCap: Double = 2.5

    // MARK: - Per-band parameters

    /// One band's prescription inputs, derived once per profile change
    /// (main thread) and handed to the realtime gain computer as plain
    /// numbers.
    struct BandParameters: Equatable {
        /// NAL-R insertion gain at the band center — the 65 dB SPL anchor.
        /// Floored at 0: the correction layer never cuts below unity
        /// (NAL-R's negative low-frequency values simply anchor at flat).
        let g65DB: Double
        /// Loss-derived compression ratio (≥ 1).
        let cr: Double
    }

    /// `CR = clamp(1 + HTL/60, 1, 2.5)`. Non-finite HTL → 1 (linear).
    static func compressionRatio(htl: Double) -> Double {
        guard htl.isFinite else { return 1 }
        return min(compressionRatioCap, max(1, 1 + htl / 60))
    }

    /// Per-band parameters for one ear, from its stored thresholds and its
    /// FULL-STRENGTH correction bands (the Phase-3 storage contract). The
    /// anchor gain is the *realised* Steady curve at the band center —
    /// composite of the fitted correction bands — so Adaptive-at-65 equals
    /// what Steady actually applies, per-band ceiling and overlap fit
    /// included.
    static func bandParameters(
        thresholds: [AudiogramPoint],
        correctionBands: [EQBand]
    ) -> [BandParameters] {
        AdaptiveFilterbank.bandCenters.map { center in
            let composite = correctionBands.isEmpty
                ? 0
                : BiquadResponse.compositeMagnitudeDB(at: center, bands: correctionBands)
            let g65 = composite.isFinite ? max(0, composite) : 0
            return BandParameters(
                g65DB: g65,
                cr: compressionRatio(htl: interpolatedHTL(thresholds, at: center))
            )
        }
    }

    /// Hearing threshold at an arbitrary frequency: linear interpolation in
    /// log-frequency between the audiogram points, clamped to the edge
    /// values outside their span. Empty audiogram → 0 (normal).
    static func interpolatedHTL(_ points: [AudiogramPoint], at hz: Double) -> Double {
        let sorted = points
            .filter { $0.thresholddBHL.isFinite && $0.frequencyHz > 0 }
            .sorted { $0.frequencyHz < $1.frequencyHz }
        guard let first = sorted.first, let last = sorted.last, hz.isFinite, hz > 0 else { return 0 }
        if hz <= Double(first.frequencyHz) { return first.thresholddBHL }
        if hz >= Double(last.frequencyHz) { return last.thresholddBHL }
        for i in 1..<sorted.count {
            let lo = sorted[i - 1], hi = sorted[i]
            let loHz = Double(lo.frequencyHz), hiHz = Double(hi.frequencyHz)
            if hz <= hiHz {
                let frac = log(hz / loHz) / log(hiHz / loHz)
                return lo.thresholddBHL + frac * (hi.thresholddBHL - lo.thresholddBHL)
            }
        }
        return last.thresholddBHL
    }

    // MARK: - The gain rule (spec §1.2)

    /// Prescribed insertion gain for one band at one estimated input level.
    ///
    /// - Parameters:
    ///   - band: the ear's parameters for this band.
    ///   - inputSPL: estimated band level at the ear
    ///     (`bandDBFS + effectiveCalibrationOffsetDBA`).
    ///   - strength: the Phase-3 effective correction strength
    ///     (target × acclimatization ramp), scaling the whole gain.
    ///   - calibrated: false → §7.3 reduced-depth cap.
    static func gainDB(
        band: BandParameters,
        inputSPL: Double,
        strength: Double,
        calibrated: Bool
    ) -> Double {
        guard band.g65DB.isFinite, band.cr.isFinite, band.cr >= 1,
              inputSPL.isFinite, strength.isFinite
        else { return 0 }

        let level = min(kneeHighSPL, max(kneeLowSPL, inputSPL))
        let slope = 1 - 1 / band.cr
        var gain = band.g65DB + (referenceSPL - level) * slope

        let extra = calibrated ? maxExtraDB : reducedMaxExtraDB
        gain = min(gain, band.g65DB + extra, absoluteCapDB)
        return max(0, gain) * min(1, max(0, strength))
    }
}
