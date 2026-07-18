import SwiftUI

/// Popover status row for the tinnitus notch: state + frequency, and a link
/// to the Tinnitus Tools screen.
///
/// Used to carry its own on/off switch — the reasoning was that a notch is
/// one filter at one pitch, simple and reversible enough to flip from here.
/// That made it the one mutating control inside an otherwise report-only
/// section (Hearing Adjustment and Adaptive Comfort both report and hand off
/// rather than edit in place). Matching that pattern: this row reports too —
/// `On · 4,000 Hz` / `Off · Configured at 4,000 Hz` — and taps through to
/// Tinnitus Tools to actually flip it, the same way every other row here
/// does.
struct TinnitusNotchRow: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button(action: openTinnitusTools) {
            HStack(spacing: 8) {
                Text("Tinnitus notch")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 108, alignment: .leading)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                // Frequency shows in both states — when off it's what the
                // notch is configured at, which the Tinnitus Tools screen
                // (one tap away) spells out in full.
                Text(stateLabel)
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
        .help("Open the Tinnitus Tools screen to change the notch.")
        .accessibilityLabel("Tinnitus notch")
        .accessibilityValue(stateLabel)
        .accessibilityHint("Opens the Tinnitus Tools screen in the main window.")
    }

    /// "On" when either ear's notch is enabled. The per-ear story lives on the
    /// Tinnitus Tools screen, so we keep this binary.
    private var notchEnabled: Bool {
        guard let p = audioState.activeProfile(in: profileStore) else { return false }
        return p.leftNotch.enabled || p.rightNotch.enabled
    }

    /// `On · 4,000 Hz` / `Off · 4,000 Hz`. Kept short so every value in the
    /// Processing details section renders at the same size — the longer
    /// "Configured at" phrasing was being shrunk to fit, which made this row
    /// read smaller than its neighbours.
    private var stateLabel: String {
        guard audioState.activeProfile(in: profileStore) != nil else { return "—" }
        return notchEnabled ? "On · \(frequencyLabel)"
                            : "Off · \(frequencyLabel)"
    }

    /// The left ear's frequency is the representative value. Adds an "L/R"
    /// split when the two ears differ (separate-notch mode with distinct
    /// values) so the readout doesn't silently lie about a divergence.
    private var frequencyLabel: String {
        guard let profile = audioState.activeProfile(in: profileStore) else { return "—" }
        let lFreq = Int(profile.leftNotch.frequencyHz)
        let rFreq = Int(profile.rightNotch.frequencyHz)
        if profile.separateNotch && lFreq != rFreq {
            return "\(lFreq.formatted()) / \(rFreq.formatted()) Hz"
        }
        return "\(lFreq.formatted()) Hz"
    }

    private func openTinnitusTools() {
        audioState.pendingMainSection = .toneFinder
        dismiss()
        AppDelegate.shared?.showMainWindow()
    }
}
