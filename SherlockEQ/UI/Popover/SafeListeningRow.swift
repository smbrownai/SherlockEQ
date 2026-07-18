import SwiftUI

/// Popover status row for Safe Listening: calibration state and the active
/// profile's personal ceiling, with a link to the Safe Listening screen.
///
/// Same shape as `HearingAdjustmentRow` and `ListeningComfortRow` — report,
/// don't edit. Calibration and the ceiling are both decisions worth making
/// deliberately on the full screen (the calibration workflow plays a
/// reference tone; the ceiling has real safety weight), not something a
/// popover row should let slip by accident.
struct SafeListeningRow: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button(action: openSafeListening) {
            HStack(spacing: 8) {
                Text("Safe Listening")
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
        .help("Open the Safe Listening screen to calibrate or change your ceiling.")
        .accessibilityLabel("Safe Listening")
        .accessibilityValue(summary)
        .accessibilityHint("Opens the Safe Listening screen in the main window.")
    }

    /// `Not calibrated · Limit 85 dB` / `Calibrated · Limit 85 dB`.
    /// Calibration is app-wide (one playback-level anchor), the limit is
    /// per-profile — both matter to "is today's exposure estimate trustworthy
    /// and where does it cap," so both show even though they're different
    /// scopes. "Limit" (not "Ceiling") matches the Safe Listening screen's own
    /// "Listening limit" control, and keeps the string short enough to render
    /// at the same size as the other rows.
    private var summary: String {
        guard let profile = audioState.activeProfile(in: profileStore) else { return "—" }
        let calibration = audioState.hasUserCalibration ? "Calibrated" : "Not calibrated"
        let limit = Int(profile.safeListeningCeilingDB.rounded())
        return "\(calibration) · Limit \(limit) dB"
    }

    private func openSafeListening() {
        audioState.pendingMainSection = .safeListening
        dismiss()
        AppDelegate.shared?.showMainWindow()
    }
}
