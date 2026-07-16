import SwiftUI

/// Popover status row for Adaptive Comfort.
///
/// This used to be a single switch plus an "N active" count. One switch can't
/// honestly represent three independently-configurable processors and the
/// Dialogue/Gentle presets layered on them: flipping it on enabled all three
/// regardless of what the user had chosen on the Adaptive Comfort screen, and
/// a bare "Off" flattened whatever mixed state sat underneath.
///
/// So it reports the state the screen actually models — `Gentle · 2 active` —
/// and hands off to that screen to change it. Deliberately no trailing switch:
/// restoring the previous per-feature configuration on toggle-back would need
/// somewhere to remember it, and a switch that silently enables all three is
/// the exact behaviour this replaces.
struct ListeningComfortRow: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button(action: openAdaptiveComfort) {
            HStack(spacing: 8) {
                Text("Adaptive Comfort")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 108, alignment: .leading)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Text(summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(activeCount > 0 ? .primary : .tertiary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(audioState.activeProfile(in: profileStore) == nil)
        .help("Open the Adaptive Comfort screen to change these features.")
        .accessibilityLabel("Adaptive Comfort")
        .accessibilityValue(summary)
        .accessibilityHint("Opens the Adaptive Comfort screen in the main window.")
    }

    private var profile: HearingProfile? {
        audioState.activeProfile(in: profileStore)
    }

    /// Features (of three) enabled on at least one ear.
    private var activeCount: Int {
        guard let profile else { return 0 }
        return DynamicFeatureKind.allCases.filter { kind in
            profile.dynamics.settings(for: kind, ear: .left).enabled
                || profile.dynamics.settings(for: kind, ear: .right).enabled
        }.count
    }

    /// `Gentle · 2 active`, or `Custom · 1 active` for a mix no preset
    /// describes. "Off" only when nothing at all is enabled — a genuinely
    /// singular state, not a mixed one being flattened.
    private var summary: String {
        guard let profile else { return "—" }
        guard activeCount > 0 else { return "Off" }
        let preset = ComfortPreset.matching(profile.dynamics)?.label ?? "Custom"
        return "\(preset) · \(activeCount) active"
    }

    private func openAdaptiveComfort() {
        audioState.pendingMainSection = .clarity
        dismiss()
        AppDelegate.shared?.showMainWindow()
    }
}
