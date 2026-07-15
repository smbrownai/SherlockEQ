import Foundation

/// Detects the tinnitus notch and the audiogram-derived hearing correction
/// fighting each other (phase3-make-correction-land.md §6).
///
/// The collision is structural, not an edge case: presbycusic tinnitus
/// overwhelmingly sits in the region of maximum hearing loss, so the notch
/// center typically lands exactly where NAL-R prescribes its largest boost.
/// A −15 dB notch against a +12 dB correction at the same frequency is one
/// filter bank arguing with itself — the user loses most of both effects
/// and gains nothing. Nothing in the app said so until this check.
///
/// Detection only — no auto-fix. Which way to lean (narrower notch keeps
/// more correction; shallower notch keeps more relief) is genuinely the
/// user's tradeoff; the chip explains it and puts both controls one click
/// away.
struct CorrectionConflict: Equatable {
    /// What the correction prescribes at the notch center (composite dB
    /// across the ear's correction bands — the same cookbook math the
    /// drawn curves use, so the numbers can't disagree with the audio).
    let correctionBoostDB: Double
    /// The notch's cut at the same frequency (negative).
    let notchDepthDB: Double
    let notchFrequencyHz: Double

    /// Correction boost at the notch center must reach this before the
    /// overlap counts as a conflict — below it, the notch is just working
    /// against ordinary tone shaping, which is fine.
    static let correctionThresholdDB: Double = 4
    /// The notch must cut at least this much (≤ −6 dB) — a shallow notch
    /// against a boost is a mild compromise, not a fight.
    static let notchDepthThresholdDB: Double = -6

    /// One-sentence explanation with the tradeoff. Numbers are rounded to
    /// whole dB — this is guidance, not metrology.
    var message: String {
        let hz = notchFrequencyHz >= 1000
            ? String(format: "%.1f kHz", notchFrequencyHz / 1000)
            : "\(Int(notchFrequencyHz)) Hz"
        return "Your hearing correction boosts +\(Int(correctionBoostDB.rounded())) dB at \(hz) — right where your notch cuts \(Int(abs(notchDepthDB).rounded())) dB. They partially cancel. A narrower notch width keeps more of the correction; a shallower notch keeps more relief."
    }

    /// Evaluate one ear: its notch against its correction layer. Returns
    /// nil when there's nothing to warn about.
    static func evaluate(notch: TinnitusNotch, correctionBands: [EQBand]) -> CorrectionConflict? {
        guard notch.enabled,
              notch.depthdB <= notchDepthThresholdDB,
              !correctionBands.isEmpty
        else { return nil }
        let boost = BiquadResponse.compositeMagnitudeDB(at: notch.frequencyHz, bands: correctionBands)
        guard boost >= correctionThresholdDB else { return nil }
        return CorrectionConflict(
            correctionBoostDB: boost,
            notchDepthDB: notch.depthdB,
            notchFrequencyHz: notch.frequencyHz
        )
    }

    /// Per-ear results for a whole profile: `(left, right)`, either nil
    /// when that ear has no conflict.
    static func evaluate(profile: HearingProfile) -> (left: CorrectionConflict?, right: CorrectionConflict?) {
        (
            evaluate(notch: profile.leftNotch, correctionBands: profile.leftEar.correctionBands),
            evaluate(notch: profile.rightNotch, correctionBands: profile.rightEar.correctionBands)
        )
    }
}
