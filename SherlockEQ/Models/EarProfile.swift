import Foundation

/// Per-ear settings: the audiogram the user entered (or imported) and the
/// resulting EQ bands derived from it. The two are kept side by side so the
/// audiogram remains editable while the realized EQ is what the audio engine
/// applies.
struct EarProfile: Codable, Hashable {
    var thresholds: [AudiogramPoint]
    var bands: [EQBand]
}

extension EarProfile {
    /// A flat starting point: normal-hearing audiogram, no EQ bands engaged.
    static var flat: EarProfile {
        EarProfile(thresholds: AudiogramPoint.flat, bands: [])
    }
}
