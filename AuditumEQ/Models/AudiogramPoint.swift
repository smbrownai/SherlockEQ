import Foundation

/// A single (frequency, threshold) pair from an audiogram report.
/// Threshold is in dB HL (hearing level) as printed on audiologist reports.
struct AudiogramPoint: Codable, Hashable {
    var frequencyHz: Int
    var thresholddBHL: Double
}

extension AudiogramPoint {
    /// The standard audiogram frequencies (Hz) used throughout the app.
    static let standardFrequencies: [Int] = [250, 500, 1000, 2000, 3000, 4000, 6000, 8000]

    /// A flat (normal-hearing) audiogram — all thresholds at 0 dB HL.
    static var flat: [AudiogramPoint] {
        standardFrequencies.map { AudiogramPoint(frequencyHz: $0, thresholddBHL: 0) }
    }
}
