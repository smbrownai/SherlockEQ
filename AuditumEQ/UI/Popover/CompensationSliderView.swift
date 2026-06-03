import SwiftUI

/// "Compensation strength" slider — the one knob from the popover. Edits the
/// active profile's `compensationFactor` (0.25…1.0 per spec §5.2) and
/// persists through `ProfileStore.save(_:)`.
struct CompensationSliderView: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore

    private let range: ClosedRange<Double> = 0.25...1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Compensation")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", currentValue * 100))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Slider(value: binding, in: range)
                .controlSize(.small)
            HStack {
                Text("Less").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("More").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .disabled(audioState.activeProfile(in: profileStore) == nil)
    }

    private var currentValue: Double {
        audioState.activeProfile(in: profileStore)?.compensationFactor ?? 0.5
    }

    private var binding: Binding<Double> {
        Binding(
            get: { currentValue },
            set: { newValue in
                guard var p = audioState.activeProfile(in: profileStore) else { return }
                p.compensationFactor = newValue
                try? profileStore.save(p)
            }
        )
    }
}
