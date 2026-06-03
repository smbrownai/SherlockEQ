import SwiftUI

/// Tinnitus notch controls (spec §5.3): on/off, frequency, depth, width.
/// Used in the Expert EQ tab. Width maps to Q (Narrow ≈ 8, Medium ≈ 4, Wide ≈ 2).
struct NotchControlView: View {
    @Binding var notch: TinnitusNotch

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Tinnitus notch", systemImage: "bandage")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: $notch.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            sliderRow(
                "Frequency",
                value: Binding(
                    get: { notch.frequencyHz },
                    set: { notch.frequencyHz = $0 }
                ),
                range: 1000...16000,
                format: { Int($0).formatted() + " Hz" }
            )

            sliderRow(
                "Depth",
                value: Binding(
                    get: { notch.depthdB },
                    set: { notch.depthdB = $0 }
                ),
                range: -15 ... -3,
                format: { String(format: "%.0f dB", $0) }
            )

            HStack {
                Text("Width")
                    .frame(width: 100, alignment: .leading)
                Picker("", selection: Binding(
                    get: { notch.qWidth },
                    set: { notch.qWidth = $0 }
                )) {
                    Text("Narrow").tag(NotchWidth.narrow)
                    Text("Medium").tag(NotchWidth.medium)
                    Text("Wide").tag(NotchWidth.wide)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                Spacer()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
        .opacity(notch.enabled ? 1.0 : 0.6)
    }

    @ViewBuilder
    private func sliderRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: @escaping (Double) -> String
    ) -> some View {
        HStack {
            Text(label).frame(width: 100, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.small)
            Text(format(value.wrappedValue))
                .font(.callout.monospaced())
                .frame(width: 88, alignment: .trailing)
        }
        .disabled(!notch.enabled)
    }
}
