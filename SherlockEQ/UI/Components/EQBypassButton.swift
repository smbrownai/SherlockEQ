import SwiftUI

/// Compact toolbar toggle for the EQ surface — flips
/// `audioState.eqChain.referenceMode` (the same state Cmd+B and the popover
/// Reference Button drive). Wording matches the popover ("Reference
/// Mode" / "Reference Mode — ON") so the two surfaces feel like one
/// control. Goes red when on so the user can't miss that they're
/// listening to unprocessed audio.
struct EQBypassButton: View {
    @EnvironmentObject private var audioState: AudioState

    var body: some View {
        Button(action: { audioState.eqChain.referenceMode.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: audioState.eqChain.referenceMode ? "circle.fill" : "circle")
                    .font(.system(size: 9))
                    .foregroundStyle(audioState.eqChain.referenceMode ? .red : .secondary)
                Text(audioState.eqChain.referenceMode ? "Reference Mode — ON" : "Reference Mode")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(audioState.eqChain.referenceMode ? .red : .primary)
            }
            // Inner-content padding inflates the toolbar pill's outer
            // shape so the dot + label don't sit flush against the
            // chrome's rounded edges. Pure visual breathing room — the
            // toolbar draws the capsule around whatever we measure here.
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(audioState.eqChain.referenceMode
              ? "Re-enable EQ processing (⌘B)"
              : "Bypass all EQ stages to hear the source unprocessed (⌘B)")
        .accessibilityLabel("Reference Mode")
        .accessibilityValue(audioState.eqChain.referenceMode ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}
