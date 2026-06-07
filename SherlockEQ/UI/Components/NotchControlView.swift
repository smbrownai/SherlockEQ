import SwiftUI

/// Tinnitus notch controls (spec §5.3): on/off, frequency, depth, width.
/// Used in the Expert EQ tab. Width maps to Q (Narrow ≈ 8, Medium ≈ 4, Wide ≈ 2).
struct NotchControlView: View {
    @Binding var notch: TinnitusNotch
    /// Header label. Defaults to "Tinnitus notch" for the shared
    /// single-notch UI; per-ear callers pass "Left ear" / "Right ear"
    /// so the two panels read as distinct without repeating the
    /// "Tinnitus notch" title twice.
    var title: String = "Tinnitus notch"
    /// Header SF Symbol. Defaults to the bandage icon used elsewhere
    /// in the app for tinnitus-related controls.
    var symbol: String = "bandage"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: symbol)
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
                    .frame(minWidth: 100, alignment: .leading).layoutPriority(1)
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
            Text(label).frame(minWidth: 100, alignment: .leading).layoutPriority(1)
            Slider(value: value, in: range)
                .controlSize(.small)
            Text(format(value.wrappedValue))
                .font(.callout.monospaced())
                .frame(minWidth: 88, alignment: .trailing)
        }
        .disabled(!notch.enabled)
    }
}
