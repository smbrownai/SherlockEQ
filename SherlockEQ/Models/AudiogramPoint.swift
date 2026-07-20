import Foundation

/// A single (frequency, threshold) pair from an audiogram report.
/// Threshold is in dB HL (hearing level) as printed on audiologist reports.
struct AudiogramPoint: Codable, Hashable {
    var frequencyHz: Int
    var thresholddBHL: Double
}

extension AudiogramPoint {
    /// The standard audiogram frequencies (Hz) used throughout the app.
    ///
    /// The full clinical set including the inter-octaves: 750 and 1500 sit in
    /// the region speech lives in, where a loss between the octave points is
    /// both common and consequential. Eight points could only interpolate
    /// across 500→1000 and 1000→2000; measuring them lets the prescription
    /// follow a real dip instead of a straight line drawn over it.
    ///
    /// Profiles written before these two joined the set are filled in at
    /// decode by `HearingProfile.fillMissingThresholds`.
    static let standardFrequencies: [Int] =
        [250, 500, 750, 1000, 1500, 2000, 3000, 4000, 6000, 8000]

    /// A flat (normal-hearing) audiogram — all thresholds at 0 dB HL.
    static var flat: [AudiogramPoint] {
        standardFrequencies.map { AudiogramPoint(frequencyHz: $0, thresholddBHL: 0) }
    }
}
