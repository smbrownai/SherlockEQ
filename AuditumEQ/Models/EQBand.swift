import Foundation

/// Filter type for an `EQBand`. Maps 1:1 to the subset of
/// `AVAudioUnitEQFilterType` values surfaced through the AuditumEQ UI.
enum EQFilterType: String, Codable, CaseIterable {
    case parametric
    case lowShelf
    case highShelf
    case notch
    case lowPass
    case highPass
}

/// A single EQ band — one biquad filter in the per-ear chain.
struct EQBand: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var frequencyHz: Double
    var gaindB: Double
    var bandwidth: Double           // Q value (parametric / notch); octaves for shelves
    var filterType: EQFilterType
    var enabled: Bool
}

extension EQBand {
    /// A flat, disabled band — useful as a placeholder slot when allocating
    /// the up-to-16-bands array per ear.
    static var disabledFlat: EQBand {
        EQBand(
            frequencyHz: 1000,
            gaindB: 0,
            bandwidth: 1.0,
            filterType: .parametric,
            enabled: false
        )
    }
}
