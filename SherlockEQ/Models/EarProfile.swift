import Foundation

/// Per-ear settings: the audiogram the user entered (or imported), the
/// audiogram-derived hearing-correction bands, and the user/preset EQ bands.
/// The three are kept side by side so the audiogram stays editable, the
/// correction it prescribes is preserved independently, and EQ presets layer
/// *on top of* the correction instead of overwriting it.
struct EarProfile: Codable, Hashable {
    var thresholds: [AudiogramPoint]
    /// User/preset EQ bands (Simple/Speech/Advanced/Expert). Presets overwrite
    /// these; the correction layer below is shielded from them.
    var bands: [EQBand]
    /// Audiogram-derived hearing-correction bands, kept SEPARATE from `bands`
    /// so EQ presets/edits never clobber the hearing prescription. The engine
    /// cascades these upstream of `bands` (the same way AutoEQ headphone
    /// correction sits ahead of profile EQ), so `bands` and `correctionBands`
    /// sum in dB rather than fighting over shared slots. Empty for profiles
    /// created before this layer existed, until their audiogram is next edited.
    var correctionBands: [EQBand] = []
}

extension EarProfile {
    /// Tolerant decoder: `correctionBands` is absent in profiles written before
    /// the correction layer existed, and decodes to `[]` (legacy behaviour —
    /// any correction baked into `bands` stays there until the audiogram is
    /// re-edited). Encoding stays synthesised. Declared in an extension so the
    /// memberwise initialiser is preserved for in-code construction.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.thresholds = try c.decode([AudiogramPoint].self, forKey: .thresholds)
        self.bands = try c.decode([EQBand].self, forKey: .bands)
        self.correctionBands = try c.decodeIfPresent([EQBand].self, forKey: .correctionBands) ?? []
    }

    /// A flat starting point: normal-hearing audiogram, no EQ or correction.
    static var flat: EarProfile {
        EarProfile(thresholds: AudiogramPoint.flat, bands: [], correctionBands: [])
    }
}
