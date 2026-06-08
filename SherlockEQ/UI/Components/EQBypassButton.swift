import SwiftUI

/// Pill toggle for the EQ surface — flips `audioState.referenceMode`
/// (the same state Cmd+B and the popover Reference Button drive).
/// Goes red + "Bypassed" when on so the user can't miss that they're
/// listening to unprocessed audio.
struct EQBypassButton: View {
    @EnvironmentObject private var audioState: AudioState

    var body: some View {
        Button(action: { audioState.referenceMode.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: audioState.referenceMode ? "circle.fill" : "circle")
                    .font(.system(size: 9))
                    .foregroundStyle(audioState.referenceMode ? .red : .secondary)
                Text(audioState.referenceMode ? "Bypassed" : "Bypass")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(audioState.referenceMode ? .red : .primary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(audioState.referenceMode
                          ? Color.red.opacity(0.14)
                          : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(audioState.referenceMode
                            ? Color.red.opacity(0.55)
                            : Color.secondary.opacity(0.28), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(audioState.referenceMode
              ? "Re-enable EQ processing (⌘B)"
              : "Bypass all EQ stages to hear the source unprocessed (⌘B)")
        .accessibilityLabel("Bypass EQ")
        .accessibilityValue(audioState.referenceMode ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}
