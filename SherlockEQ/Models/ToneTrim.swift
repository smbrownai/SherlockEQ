import Foundation

/// The three-band tone layout — bass shelf / mid bell / treble shelf.
///
/// Written by the `sherlockeq simple-eq` command, the Shortcuts/Siri intents,
/// and the Analog Control Unit's knobs. It is a **first-class band layout**,
/// not leftover state: the Graphic surface owns these slots (see
/// `EQMode.ownedSlots`), so a tone trim no longer lands in the "Other filters"
/// row where the only offers were to convert it away or leave the Graphic
/// screen. The Graphic screen reports it instead.
///
/// **The Mid slot is the Graphic screen's 1 kHz slider.** `(1000 Hz,
/// .parametric)` is both this layout's mid band and a member of
/// `EQMode.graphicCenters` — the same stored band, reached two ways. That is
/// deliberate (a mid bell at 1 kHz is what both surfaces want) but it means
/// only `offGrid` — the two shelves — is invisible to the sliders and needs
/// reporting. See `offGrid`.
/// (Not `nonisolated`: it reads `EQMode.graphicCenters` and `EQBandLookup`,
/// both MainActor-isolated like the rest of the model layer, and every caller
/// — the Graphic screen, `EQMode.ownedSlots`, `AppControlService` — is already
/// on the main actor.)
enum ToneTrim {

    struct Slot: Hashable {
        /// Wire key for the CLI / intents (`--bass`, `--mid`, `--treble`).
        let key: String
        /// Display name for UI readouts.
        let label: String
        let frequencyHz: Double
        let filterType: EQFilterType
    }

    /// 1 octave — matches the graphic sliders' bandwidth so a mid trim and the
    /// 1 kHz slider are genuinely the same filter, not two shapes at one
    /// frequency.
    static let bandwidth: Double = 1.0

    /// Accepted range for the CLI / intents. Wider than the graphic sliders'
    /// ±12 because it long predates them and scripts depend on it.
    static let range: ClosedRange<Double> = -24...24

    /// `key` is the CLI/intents wire word and must stay stable, untranslated
    /// English — a script writes `--bass`. `label` is display text, so it goes
    /// through `String(localized:)`: it reaches the Graphic screen's tone-trim
    /// line via `Text(_ String)`, which renders verbatim without localizing.
    static let slots: [Slot] = [
        Slot(key: "bass",
             label: String(localized: "Bass", comment: "Tone-trim band: low shelf at 250 Hz"),
             frequencyHz: 250,  filterType: .lowShelf),
        Slot(key: "mid",
             label: String(localized: "Mid", comment: "Tone-trim band: bell at 1 kHz"),
             frequencyHz: 1000, filterType: .parametric),
        Slot(key: "treble",
             label: String(localized: "Treble", comment: "Tone-trim band: high shelf at 5 kHz"),
             frequencyHz: 5000, filterType: .highShelf),
    ]

    /// The slots the Graphic sliders can't show — the two shelves. Mid is
    /// excluded because it *is* the 1 kHz slider: listing it in a tone-trim
    /// readout would print the same value the slider already displays, the
    /// duplicate-signal problem this app removes elsewhere.
    ///
    /// Derived rather than hardcoded, so adding a graphic center at a
    /// tone-trim frequency automatically drops it from the readout instead of
    /// silently double-reporting.
    static var offGrid: [Slot] {
        let graphic = Set(EQMode.graphicCenters)
        return slots.filter { slot in
            !(slot.filterType == .parametric && graphic.contains(slot.frequencyHz))
        }
    }

    /// Current dB for each off-grid slot in `bands`, dropping the ones sitting
    /// at zero. Empty when there's no tone trim to report.
    static func offGridValues(in bands: [EQBand]) -> [(slot: Slot, gainDB: Double)] {
        offGrid.compactMap { slot in
            let gain = EQBandLookup.gain(at: slot.frequencyHz, filterType: slot.filterType, in: bands)
            guard abs(gain) >= 0.05 else { return nil }
            return (slot, gain)
        }
    }
}
