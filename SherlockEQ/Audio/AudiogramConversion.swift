import Foundation

/// Converts an audiogram (per-frequency hearing thresholds in dB HL) into a
/// set of `EQBand` values that the audio engine can apply.
///
/// Algorithm per spec §5.2:
///   gain_at_freq = threshold_dBHL × compensation_factor
/// with a per-band hard ceiling of +20 dB and only enabled when the loss is
/// audibly meaningful (≥ 5 dB HL pre-compensation).
///
/// We currently emit one band per audiogram frequency. Cubic-spline-derived
/// intermediate bands (mentioned in §5.2) can be layered on later without
/// changing this signature — `bands(for:compensationFactor:)` would simply
/// return more points.
enum AudiogramConversion {

    /// Maximum boost any single band can carry, regardless of measured loss.
    /// Protects the user from runaway gain in case of unusual audiograms or
    /// data-entry mistakes.
    static let perBandCeilingDB: Double = 20.0

    /// Threshold (dB HL) below which a frequency is considered "fine" and we
    /// leave the band disabled to keep the EQ chain inactive where it isn't
    /// needed.
    private static let minimumActionableLossDB: Double = 5.0

    /// Compute EQ bands directly from the audiogram thresholds.
    /// - Parameters:
    ///   - audiogram: per-frequency dB HL values (typically 8 points).
    ///   - compensationFactor: 0.25–1.0 user-controlled strength.
    /// - Returns: bands sorted by frequency, each tied 1:1 to an audiogram point.
    static func bands(
        for audiogram: [AudiogramPoint],
        compensationFactor: Double
    ) -> [EQBand] {
        let cf = max(0.0, min(1.0, compensationFactor))
        return audiogram
            .sorted { $0.frequencyHz < $1.frequencyHz }
            .map { point in
                let rawGain = point.thresholddBHL * cf
                let clamped = max(0.0, min(perBandCeilingDB, rawGain))
                let enabled = point.thresholddBHL >= minimumActionableLossDB && clamped > 0
                return EQBand(
                    frequencyHz: Double(point.frequencyHz),
                    gaindB: clamped,
                    bandwidth: 1.0,                 // octaves — sensible default Q
                    filterType: .parametric,
                    enabled: enabled
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
}
