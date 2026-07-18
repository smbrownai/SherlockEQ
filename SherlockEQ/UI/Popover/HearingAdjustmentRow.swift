import SwiftUI

/// Popover status row for the audiogram-derived hearing adjustment.
///
/// Replaces the old "Compensation" slider. That slider was a single 0.25–1.0
/// knob labelled `Less — More`, which stopped being answerable once the
/// adjustment grew layers: which of the audiogram adjustment, Steady vs
/// Adaptive, the gradual introduction, manual EQ, or headphone correction was
/// it moving? It also let the popover shove the strength around behind the
/// back of the Audiogram screen's carefully-explained flow.
///
/// So the popover reports instead of edits — `Audiogram · Steady · 61%` — and
/// hands off to the Audiogram screen for the actual configuration.
struct HearingAdjustmentRow: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button(action: openAudiogram) {
            HStack(spacing: 8) {
                Text("Hearing adjustment")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 108, alignment: .leading)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Text(summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(audioState.activeProfile(in: profileStore) == nil)
        .help("Open the Audiogram screen to change the hearing adjustment.")
        .accessibilityLabel("Hearing adjustment")
        .accessibilityValue(summary)
        .accessibilityHint("Opens the Audiogram screen in the main window.")
    }

    private var profile: HearingProfile? {
        audioState.activeProfile(in: profileStore)
    }

    /// Matches the Profile Detail summary card: an adjustment exists when the
    /// audiogram actually derived correction bands. A flat/normal audiogram
    /// derives none, so there's nothing to report.
    private var hasAdjustment: Bool {
        guard let profile else { return false }
        return !profile.leftEar.correctionBands.isEmpty
            || !profile.rightEar.correctionBands.isEmpty
    }

    /// `Audiogram · Steady · 61%` — source, style, and the strength actually
    /// being applied right now (the gradual ramp scales it, so this is
    /// `effectiveCorrectionStrength`, not the raw target).
    private var summary: String {
        guard let profile else { return "—" }
        guard hasAdjustment else { return "No audiogram" }
        let style = profile.correctionMode == .adaptive ? "Adaptive" : "Steady"
        let percent = Int((profile.effectiveCorrectionStrength() * 100).rounded())
        return "Audiogram · \(style) · \(percent)%"
    }

    private func openAudiogram() {
        // Set the destination before the window exists — MainWindowView picks
        // a pending section up in onAppear as well as onChange.
        audioState.pendingMainSection = .audiogram
        dismiss()
        AppDelegate.shared?.showMainWindow()
    }
}
