import SwiftUI

/// Prominent "Reference Mode" toggle for the popover. Sets `.bypass = true`
/// on all EQ nodes simultaneously — instant A/B between processed and
/// unprocessed audio.
///
/// Deliberately the loudest control here: rapid A/B is the thing people want
/// *without* opening a window, which is exactly what a popover is for. The
/// subtitle spells out what it does, because "Reference Mode" alone doesn't
/// say that everything gets bypassed.
struct ReferenceButton: View {
    @EnvironmentObject private var audioState: AudioState

    private var isOn: Bool { audioState.eqChain.referenceMode }

    var body: some View {
        Button(action: { audioState.eqChain.referenceMode.toggle() }) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "circle.fill" : "circle")
                    .foregroundStyle(isOn ? .red : .secondary)
                    .font(.system(size: 10))
                VStack(alignment: .leading, spacing: 1) {
                    Text(isOn ? "Reference Mode On — processing bypassed"
                              : "Reference Mode")
                        .font(.callout.weight(.medium))
                    Text(isOn ? "Tap to resume processing"
                              : "Temporarily bypass all processing")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isOn ? Color.red.opacity(0.12) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isOn ? Color.red.opacity(0.5) : Color.secondary.opacity(0.2))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reference Mode")
        .accessibilityValue(isOn ? "On, processing bypassed" : "Off")
        .accessibilityHint("Temporarily bypasses all processing so you hear the source unchanged.")
    }
}
