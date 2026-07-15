import SwiftUI

/// Tinnitus notch controls (spec §5.3): on/off, strength preset, frequency,
/// and — behind an advanced disclosure — depth and width.
///
/// The framing is deliberately comfort-oriented: the notch reduces audio
/// energy around the selected pitch, trading a little clarity for a little
/// relief. It is not a treatment and does not remove tinnitus. Copy here
/// teaches that trade-off rather than implying a fix. Width maps to Q
/// (Narrow ≈ 8, Medium ≈ 4, Wide ≈ 2) — the real octave span is surfaced so
/// the friendly labels aren't opaque.
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

    /// Advanced depth/width live behind a disclosure so the primary surface
    /// stays "on/off + strength + pitch". Expanded state is per-panel and
    /// intentionally not persisted — it's a momentary "show me the details".
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Text("What you'll hear: audio may sound slightly softer or less sharp near this pitch. A narrow notch stays clearer; a wider or deeper one sounds more muffled, especially on speech.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            strengthRow

            sliderRow(
                "Frequency",
                help: "The pitch area being reduced. Set it from Tone Finder above, or fine-tune here.",
                value: Binding(
                    get: { notch.frequencyHz },
                    set: { notch.frequencyHz = $0 }
                ),
                range: 1000...16000,
                format: { Int($0).formatted() + " Hz" }
            )

            advancedDisclosure
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
        .opacity(notch.enabled ? 1.0 : 0.6)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Label(title, systemImage: symbol)
                .font(.headline)
            Spacer()
            Toggle("", isOn: $notch.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var strengthRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Strength")
                    .frame(minWidth: 100, alignment: .leading).layoutPriority(1)
                Picker("", selection: presetSelection) {
                    ForEach(NotchPreset.allCases) { preset in
                        Text(preset.label).tag(NotchPreset?.some(preset))
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                if notch.preset == nil {
                    Text("Custom")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(notch.preset?.blurb ?? "Custom depth and width set below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!notch.enabled)
    }

    private var advancedDisclosure: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                sliderRow(
                    "Depth",
                    help: "How much that pitch area is lowered. More depth reduces sharpness but can make audio sound less natural.",
                    value: Binding(
                        get: { notch.depthdB },
                        set: { notch.depthdB = $0 }
                    ),
                    range: -15 ... -3,
                    format: { String(format: "%.0f dB", $0) }
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Width")
                            .frame(minWidth: 100, alignment: .leading).layoutPriority(1)
                        Picker("", selection: Binding(
                            get: { notch.qWidth },
                            set: { notch.qWidth = $0 }
                        )) {
                            ForEach(NotchWidth.allCases, id: \.self) { w in
                                Text(w.label).tag(w)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 240)
                        Text(notch.qWidth.detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text("How much surrounding sound is affected. Narrow preserves clarity; wide sounds stronger but can dull speech and music.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 8)
            .disabled(!notch.enabled)
        } label: {
            Text("Fine-tune notch")
                .font(.subheadline.weight(.medium))
        }
        .disabled(!notch.enabled)
    }

    // MARK: - Bindings

    /// Reflects the current preset (nil when custom, showing no segment
    /// selected). Selecting a segment applies that preset's width + depth.
    private var presetSelection: Binding<NotchPreset?> {
        Binding(
            get: { notch.preset },
            set: { newValue in
                if let preset = newValue { notch.apply(preset) }
            }
        )
    }

    @ViewBuilder
    private func sliderRow(
        _ label: String,
        help: String? = nil,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).frame(minWidth: 100, alignment: .leading).layoutPriority(1)
                Slider(value: value, in: range)
                    .controlSize(.small)
                Text(format(value.wrappedValue))
                    .font(.callout.monospaced())
                    .frame(minWidth: 88, alignment: .trailing)
            }
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!notch.enabled)
    }
}
