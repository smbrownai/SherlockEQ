import Foundation

/// A quick tone adjustment that moves several **graphic bands at once**.
///
/// This is deliberately *not* a filter. There is no stored "bass" value and no
/// bass band — a macro is a gesture that adds a fixed weighting vector to the
/// twelve graphic gains and then stops existing. The 12-band curve remains the
/// single source of truth: opening the Equalizer shows exactly what a nudge
/// did, because a nudge did nothing except move those sliders.
///
/// That's the difference from `ToneTrim`, which is a real three-band shelf
/// layout with real stored parameters. `ToneTrim` is right for the CLI,
/// Shortcuts, and the Analog unit, where a script needs a stable `--bass 3` to
/// set and read back. It's wrong for the popover, where a persistent
/// "Bass: +2 dB" fader would have to claim one authoritative bass value for an
/// arbitrary 12-band curve — a number that can't survive the user touching the
/// Graphic sliders. Relative nudges make no such claim.
///
/// **Weights are keyed by frequency, not by array position.** Positional
/// vectors silently re-shape themselves if `EQMode.graphicCenters` ever gains
/// or reorders a band; a frequency that isn't a center simply contributes
/// nothing, and `ToneMacroTests` pins that every key is a real center.
///
/// (Not `nonisolated`, for the same reason as `ToneTrim`: it reads
/// `EQMode.graphicCenters` and `EQBandLookup`, both MainActor-isolated.)
enum ToneMacro: String, CaseIterable, Identifiable {
    case bass, mid, treble

    var id: String { rawValue }

    // MARK: - Shape

    /// dB per nudge at full weight. One dB is small enough that a press is a
    /// nudge rather than a commitment, and large enough to hear.
    static let step: Double = 1.0

    /// The graphic sliders' own range. Clamping here rather than at the band
    /// range means a macro can never push the curve somewhere the Graphic
    /// screen can't display or the user can't drag back.
    static let limit: ClosedRange<Double> = -12...12

    /// Weight per graphic center. Broad and overlapping by design — the point
    /// of a macro is to move a *region*, so the shoulders taper instead of
    /// ending on a cliff that would read as a resonance.
    var weights: [Double: Double] {
        switch self {
        // Low shelf-ish: flat through the bottom two octaves, tapering out
        // through 500 Hz so a bass nudge never muddies vocal fundamentals.
        case .bass:
            return [31.5: 1.0, 63: 1.0, 125: 0.9, 250: 0.6, 500: 0.2]
        // A broad hump over the presence region, symmetric about 1 kHz —
        // 250 and 4000 are each two octaves out, and carry equal weight.
        case .mid:
            return [250: 0.3, 500: 0.8, 1000: 1.0, 2000: 0.8, 4000: 0.3]
        // Mirror of bass: flat across the top, tapering down toward 2 kHz.
        // One shoulder rather than bass's two, because the grid is an octave
        // apart up here — 0.4 splits the old 3 kHz/2 kHz pair it replaces.
        case .treble:
            return [2000: 0.4, 4000: 0.9, 8000: 1.0, 16000: 1.0]
        }
    }

    /// Centers this macro actually touches, in ascending order.
    var centers: [Double] {
        EQMode.graphicCenters.filter { (weights[$0] ?? 0) != 0 }
    }

    // MARK: - Naming

    // Every user-facing string below goes through `String(localized:)`.
    //
    // These are returned as `String` and rendered with `Text(_ String)`, which
    // does NOT localize — a bare `return "Recess"` would be permanently
    // English and, worse, invisible to Xcode's string extractor, so it would
    // never even appear in the catalog to be noticed. Only literals written
    // directly into `Text("…")` / `Label("…")` get picked up automatically.

    /// Row label. "Mids" plural — it's a region, not a band.
    var label: String {
        switch self {
        case .bass:   return String(localized: "Bass", comment: "Tone region: low frequencies")
        case .mid:    return String(localized: "Mids", comment: "Tone region: middle frequencies, around 500 Hz–2 kHz")
        case .treble: return String(localized: "Treble", comment: "Tone region: high frequencies")
        }
    }

    /// Short button titles. The row label supplies the noun, so the buttons
    /// only carry the direction and stay narrow enough for a 380 pt popover.
    /// Translators get the noun via the comment, since the button text alone
    /// doesn't say what it acts on.
    func buttonTitle(_ direction: Direction) -> String {
        switch (self, direction) {
        case (.bass, .down):
            return String(localized: "Less", comment: "Button: reduce bass. Paired with 'More' on the Bass row")
        case (.bass, .up):
            return String(localized: "More", comment: "Button: increase bass. Paired with 'Less' on the Bass row")
        case (.mid, .down):
            return String(localized: "Recess", comment: "Button: push mids back in the mix. Paired with 'Forward' on the Mids row")
        case (.mid, .up):
            return String(localized: "Forward", comment: "Button: bring mids forward in the mix. Paired with 'Recess' on the Mids row")
        case (.treble, .down):
            return String(localized: "Softer", comment: "Button: reduce treble. Paired with 'Brighter' on the Treble row")
        case (.treble, .up):
            return String(localized: "Brighter", comment: "Button: increase treble. Paired with 'Softer' on the Treble row")
        }
    }

    /// The full phrase, for VoiceOver and the undo action name. The buttons
    /// show only the direction, so a bare "Recess" or "More" carries no
    /// indication of *what* it moves — VoiceOver needs the noun (audit UX-03).
    func actionName(_ direction: Direction) -> String {
        switch (self, direction) {
        case (.bass, .down):
            return String(localized: "Less bass", comment: "Accessibility label and undo title for one bass-down nudge")
        case (.bass, .up):
            return String(localized: "More bass", comment: "Accessibility label and undo title for one bass-up nudge")
        case (.mid, .down):
            return String(localized: "Recess mids", comment: "Accessibility label and undo title for one mids-down nudge")
        case (.mid, .up):
            return String(localized: "Forward mids", comment: "Accessibility label and undo title for one mids-up nudge")
        case (.treble, .down):
            return String(localized: "Softer treble", comment: "Accessibility label and undo title for one treble-down nudge")
        case (.treble, .up):
            return String(localized: "Brighter treble", comment: "Accessibility label and undo title for one treble-up nudge")
        }
    }

    enum Direction {
        case up, down
        var sign: Double { self == .up ? 1 : -1 }
    }

    // MARK: - Applying

    /// What a nudge actually managed to do.
    struct Outcome: Equatable {
        /// Bands whose gain changed.
        var moved: Int
        /// Bands that hit the ±12 rail and so moved less than asked (or not
        /// at all). Non-zero means the user got less than they pressed for,
        /// which the popover says out loud rather than silently swallowing.
        var clamped: Int
        /// Nothing moved — the whole region is already at the rail.
        var isNoOp: Bool { moved == 0 }
    }

    /// Add this macro's weighted delta to the current graphic gains in `bands`.
    ///
    /// Deltas, not targets: the existing curve is read and added to, never
    /// re-fitted. Nothing here tries to solve for a shelf shape, so repeated
    /// nudges accumulate exactly as the arithmetic suggests and a nudge in one
    /// direction followed by its opposite returns to where it started (except
    /// where a rail intervened, which `Outcome.clamped` reports).
    @discardableResult
    static func apply(_ macro: ToneMacro, direction: Direction,
                      step: Double = ToneMacro.step, to bands: inout [EQBand]) -> Outcome {
        var outcome = Outcome(moved: 0, clamped: 0)
        for center in macro.centers {
            guard let weight = macro.weights[center] else { continue }
            let current = EQBandLookup.gain(at: center, filterType: .parametric, in: bands)
            let desired = current + step * direction.sign * weight
            let clamped = min(max(desired, limit.lowerBound), limit.upperBound)
            if abs(clamped - desired) > 0.0001 { outcome.clamped += 1 }
            guard abs(clamped - current) > 0.0001 else { continue }
            outcome.moved += 1
            EQBandLookup.setGain(clamped, at: center, bandwidth: graphicBandwidth,
                                 filterType: .parametric, in: &bands)
        }
        return outcome
    }

    /// 1 octave — the Graphic surface's own Q. Macros must produce bands that
    /// are indistinguishable from ones dragged on that screen, or the "the
    /// main EQ is the source of truth" promise would be a half-truth.
    static let graphicBandwidth: Double = 1.0
}
