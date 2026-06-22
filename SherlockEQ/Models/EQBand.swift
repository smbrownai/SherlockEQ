import Foundation

/// Filter type for an `EQBand`. Maps 1:1 to the subset of
/// `AVAudioUnitEQFilterType` values surfaced through the SherlockEQ UI.
enum EQFilterType: String, Codable, CaseIterable {
    case parametric
    case lowShelf
    case highShelf
    case notch
    case bandPass
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

    init(
        id: UUID = UUID(),
        frequencyHz: Double,
        gaindB: Double,
        bandwidth: Double,
        filterType: EQFilterType,
        enabled: Bool
    ) {
        self.id = id
        self.frequencyHz = frequencyHz
        self.gaindB = gaindB
        self.bandwidth = bandwidth
        self.filterType = filterType
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, frequencyHz, gaindB, bandwidth, filterType, enabled
    }

    // Custom decoder so `id` is optional on disk: hand-edited or third-party
    // profile JSON that omits per-band ids should still load. A synthesised
    // decoder treats a property with a default value as still-required, so a
    // missing `id` previously failed the entire profile decode (the file then
    // silently vanished from the list / refused to import). Mint a fresh id
    // when absent; encoding stays synthesised so saved files keep their ids.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.frequencyHz = try c.decode(Double.self, forKey: .frequencyHz)
        self.gaindB = try c.decode(Double.self, forKey: .gaindB)
        self.bandwidth = try c.decode(Double.self, forKey: .bandwidth)
        self.filterType = try c.decode(EQFilterType.self, forKey: .filterType)
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
    }
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

    /// Equality ignoring `id`. Two bands compare audibly the same when
    /// they describe the same filter behaviour, even if they were
    /// constructed independently per ear (and so carry different
    /// UUIDs). The built-in `==` uses `id`, so the synthesised
    /// `Hashable` conformance can stay identity-aware for diffable
    /// lists while we get a content-aware predicate here.
    func audiblySame(as other: EQBand) -> Bool {
        frequencyHz == other.frequencyHz
            && gaindB == other.gaindB
            && bandwidth == other.bandwidth
            && filterType == other.filterType
            && enabled == other.enabled
    }
}

extension Array where Element == EQBand {
    /// Audio-equivalent comparison ignoring band IDs. Sorts both
    /// arrays by (frequency, filter type) so authoring order doesn't
    /// flip the result. Use this when asking "do the L and R chains
    /// describe the same EQ?" — `==` on the arrays will be false the
    /// moment the bands have different UUIDs, which they almost
    /// always do because Simple/Speech/Advanced/EQBandLookup mint
    /// fresh bands per ear and Expert's mirror function preserves
    /// the target ear's existing IDs by design.
    func audiblyEquivalent(to other: [EQBand]) -> Bool {
        guard count == other.count else { return false }
        let lhs = sorted { ($0.frequencyHz, $0.filterType.rawValue) < ($1.frequencyHz, $1.filterType.rawValue) }
        let rhs = other.sorted { ($0.frequencyHz, $0.filterType.rawValue) < ($1.frequencyHz, $1.filterType.rawValue) }
        for (a, b) in zip(lhs, rhs) {
            if !a.audiblySame(as: b) { return false }
        }
        return true
    }
}
