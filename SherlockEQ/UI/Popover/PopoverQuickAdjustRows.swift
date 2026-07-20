import SwiftUI

/// Quick tone adjustments — stepped nudges that move the twelve graphic bands.
///
/// Buttons rather than faders, on purpose. A fader has to display a value, and
/// there is no honest "Bass: +2 dB" to display for an arbitrary 12-band curve:
/// the moment the user drags a Graphic slider, any such number is a fiction.
/// A nudge claims nothing. It applies a relative change and returns to
/// neutral, leaving the actual state visible where it really lives — the
/// miniature curve just above, and the Equalizer screen.
///
/// **There is no undo button because the opposite button is the undo.** Every
/// pair is exactly symmetric: nudges are additive deltas, so More→Less returns
/// to the starting gains bit for bit (`ToneMacroTests.oppositeNudgesCancel`
/// pins this). A dedicated undo would have been a second control doing the
/// same job as one already on screen, plus the snapshot-staleness machinery
/// needed to keep it from clobbering edits made elsewhere in between.
///
/// The one asymmetry is at the rails: if a nudge was clamped at ±12, the
/// reverse nudge subtracts the full weighted amount and lands lower than the
/// start. That's why clamping is called out below rather than passed over.
///
/// See `ToneMacro` for the weighting vectors and why these aren't filters.
struct PopoverQuickAdjustRows: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore

    /// Result of the last nudge. Transient by design — it explains a press
    /// that couldn't do what was asked, then gets out of the way on the next
    /// one rather than becoming ambient text the user stops reading.
    @State private var note: String?

    var body: some View {
        if let profile = audioState.activeProfile(in: profileStore) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ToneMacro.allCases) { macro in
                    row(macro)
                }
                if let note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            // A note about one profile's limits is meaningless against another.
            .onChange(of: profile.id) { _, _ in note = nil }
        }
    }

    @ViewBuilder
    private func row(_ macro: ToneMacro) -> some View {
        HStack(spacing: 8) {
            Text(macro.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)
            button(macro, .down)
            button(macro, .up)
        }
    }

    @ViewBuilder
    private func button(_ macro: ToneMacro, _ direction: ToneMacro.Direction) -> some View {
        Button { nudge(macro, direction) } label: {
            Text(macro.buttonTitle(direction))
                .font(.caption)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        // The visible title is only half the phrase ("Softer") and appears on
        // two different rows — VO needs the whole thing (audit UX-03).
        .accessibilityLabel(macro.actionName(direction))
    }

    // MARK: - Action

    /// Apply one nudge to both ears.
    ///
    /// Both ears get the *same delta*, which is what makes this safe for
    /// asymmetric profiles: adding a constant to each ear preserves whatever
    /// L/R difference the user or their audiogram established, where writing
    /// an absolute value to both would flatten it.
    private func nudge(_ macro: ToneMacro, _ direction: ToneMacro.Direction) {
        // Live copy, not a body-render snapshot — saving the stale struct
        // would clobber concurrent edits from the main window (audit CX-05).
        guard let live = audioState.activeProfile(in: profileStore) else { return }
        var updated = profileStore.profiles.first { $0.id == live.id } ?? live

        var worst = ToneMacro.Outcome(moved: 0, clamped: 0)
        EQBandLookup.mutateBothEars(of: &updated) { bands in
            let outcome = ToneMacro.apply(macro, direction: direction, to: &bands)
            // Ears can clip independently on an asymmetric profile; report the
            // more constrained one so the message is never rosier than what
            // the user actually got.
            worst = ToneMacro.Outcome(moved: max(worst.moved, outcome.moved),
                                      clamped: max(worst.clamped, outcome.clamped))
        }

        guard !worst.isNoOp else {
            // Nothing moved, so there's nothing to save. Say so — a button
            // that silently does nothing reads as broken.
            note = "\(macro.label) is already at its limit."
            return
        }
        note = worst.clamped > 0
            ? "Some bands are at their limit, so the change was partial."
            : nil

        // One save per press → one undo entry in the main window's
        // UndoManager, which ProfileStore registers against when it's open.
        try? profileStore.save(updated, actionName: macro.actionName(direction))
    }
}
