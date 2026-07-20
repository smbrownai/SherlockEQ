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
/// See `ToneMacro` for the weighting vectors and why these aren't filters.
struct PopoverQuickAdjustRows: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore
    @ObservedObject private var history = QuickAdjustHistory.shared

    var body: some View {
        if let profile = audioState.activeProfile(in: profileStore) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ToneMacro.allCases) { macro in
                    row(macro)
                }
                footer(profile)
            }
            // A profile switch makes any snapshot meaningless — drop it as the
            // profile changes rather than waiting for the staleness check, so
            // the button never flickers into view against the wrong profile.
            .onChange(of: profile.id) { _, _ in history.clear() }
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

    @ViewBuilder
    private func footer(_ profile: HearingProfile) -> some View {
        let undoable = history.usableSnapshot(for: profile)
        if undoable != nil || history.note != nil {
            HStack(spacing: 8) {
                if let note = history.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let snapshot = undoable {
                    Button { undo(snapshot) } label: {
                        Label("Undo quick adjustment", systemImage: "arrow.uturn.backward")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("Undo \(snapshot.actionName)")
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Actions

    /// Apply one nudge to both ears and record a single undo step.
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

        let centers = macro.centers
        let previousLeft = ToneMacro.gains(at: centers, in: updated.leftEar.bands)
        let previousRight = ToneMacro.gains(at: centers, in: updated.rightEar.bands)

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
            // Nothing changed, so there's nothing to undo and no save to make.
            // Leave any existing snapshot alone — it's still valid.
            history.setNote("\(macro.label) is already at its limit.")
            return
        }

        let snapshot = QuickAdjustHistory.Snapshot(
            profileID: updated.id,
            centers: centers,
            previousLeft: previousLeft,
            previousRight: previousRight,
            expectedLeft: ToneMacro.gains(at: centers, in: updated.leftEar.bands),
            expectedRight: ToneMacro.gains(at: centers, in: updated.rightEar.bands),
            actionName: macro.actionName(direction)
        )
        history.record(snapshot, note: worst.clamped > 0
                       ? "Some bands are at their limit, so the change was partial."
                       : nil)

        // One save per press → one undo entry, both here and in the main
        // window's UndoManager (which ProfileStore registers against when the
        // window is open).
        try? profileStore.save(updated, actionName: macro.actionName(direction))
    }

    private func undo(_ snapshot: QuickAdjustHistory.Snapshot) {
        guard let live = audioState.activeProfile(in: profileStore) else { return }
        var updated = profileStore.profiles.first { $0.id == live.id } ?? live
        ToneMacro.restore(snapshot.previousLeft, at: snapshot.centers, in: &updated.leftEar.bands)
        ToneMacro.restore(snapshot.previousRight, at: snapshot.centers, in: &updated.rightEar.bands)
        history.clear()
        try? profileStore.save(updated, actionName: "Undo \(snapshot.actionName)")
    }
}
