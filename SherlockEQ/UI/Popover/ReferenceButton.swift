import SwiftUI

/// Prominent "Reference Mode" toggle for the popover. Sets `.bypass = true`
/// on all EQ nodes simultaneously — instant A/B between processed and
/// unprocessed audio.
struct ReferenceButton: View {
    @EnvironmentObject private var audioState: AudioState

    var body: some View {
        Button(action: { audioState.referenceMode.toggle() }) {
            HStack(spacing: 8) {
                Image(systemName: audioState.referenceMode ? "circle.fill" : "circle")
                    .foregroundStyle(audioState.referenceMode ? .red : .secondary)
                    .font(.system(size: 10))
                Text(audioState.referenceMode ? "Reference Mode — ON" : "Reference Mode")
                    .font(.callout.weight(.medium))
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(audioState.referenceMode ? Color.red.opacity(0.12) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(audioState.referenceMode ? Color.red.opacity(0.5) : Color.secondary.opacity(0.2))
            )
        }
        .buttonStyle(.plain)
    }
}
