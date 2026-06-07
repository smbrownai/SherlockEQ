import Foundation

/// Width of the tinnitus notch filter. Maps to a Q value when realized as a
/// biquad band (`narrow ~ Q 8`, `medium ~ Q 4`, `wide ~ Q 2`) per the spec.
enum NotchWidth: String, Codable, CaseIterable {
    case narrow
    case medium
    case wide

    var qValue: Double {
        switch self {
        case .narrow: return 8.0
        case .medium: return 4.0
        case .wide: return 2.0
        }
    }
}

/// Configuration for the per-profile tinnitus notch filter.
struct TinnitusNotch: Codable, Hashable {
    var enabled: Bool
    var frequencyHz: Double       // typically 1000–16000
    var depthdB: Double           // negative — typically -3 to -15
    var qWidth: NotchWidth
}

extension TinnitusNotch {
    /// Sensible default: disabled, mid-range placeholder until the user runs Tone Finder.
    static var disabled: TinnitusNotch {
        TinnitusNotch(
            enabled: false,
            frequencyHz: 4000,
            depthdB: -6,
            qWidth: .medium
        )
    }
}
