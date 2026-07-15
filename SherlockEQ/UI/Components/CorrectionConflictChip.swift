import SwiftUI

/// Persistent inline warning that the tinnitus notch and the audiogram
/// correction are fighting at the notch pitch (spec §6 / `CorrectionConflict`).
/// Mounted on the Tinnitus Notch screen and the Audiogram screen — the two
/// surfaces that own the colliding controls — with a deep-link to whichever
/// one the user isn't currently on.
///
/// Durable state, not a transient event, so it's a chip rather than a
/// NoticeCenter banner (same reasoning as the AutoEQ mismatch row). And no
/// auto-fix: the narrower-vs-shallower tradeoff is the user's to make.
struct CorrectionConflictChip: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore

    /// Where to offer navigation — the surface the chip is NOT on.
    enum CrossLink {
        case tinnitusNotch   // chip lives on the Audiogram screen
        case audiogram       // chip lives on the Tinnitus Notch screen
    }
    let crossLink: CrossLink

    var body: some View {
        if let profile = audioState.activeProfile(in: profileStore) {
            let conflicts = CorrectionConflict.evaluate(profile: profile)
            if conflicts.left != nil || conflicts.right != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let both = identicalOnBothEars(conflicts) {
                        conflictLine(both, ear: nil)
                    } else {
                        if let left = conflicts.left { conflictLine(left, ear: "Left ear") }
                        if let right = conflicts.right { conflictLine(right, ear: "Right ear") }
                    }
                    HStack {
                        Button(crossLink == .audiogram ? "Open Audiogram" : "Open Tinnitus Notch") {
                            audioState.pendingMainSection =
                                crossLink == .audiogram ? .audiogram : .toneFinder
                        }
                        .controlSize(.small)
                        .help(crossLink == .audiogram
                              ? "Adjust the hearing-adjustment strength on the Audiogram screen."
                              : "Adjust the notch depth or width on the Tinnitus Notch screen.")
                        Spacer()
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.orange.opacity(0.35))
                )
                .accessibilityElement(children: .contain)
            }
        }
    }

    /// Linked notches on a symmetric audiogram produce the same conflict on
    /// both ears — collapse to one line instead of repeating the numbers.
    private func identicalOnBothEars(
        _ conflicts: (left: CorrectionConflict?, right: CorrectionConflict?)
    ) -> CorrectionConflict? {
        guard let l = conflicts.left, let r = conflicts.right, l == r else { return nil }
        return l
    }

    @ViewBuilder
    private func conflictLine(_ conflict: CorrectionConflict, ear: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "waveform.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text(ear.map { "\($0): \(conflict.message)" } ?? conflict.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
