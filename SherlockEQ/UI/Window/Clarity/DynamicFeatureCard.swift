import SwiftUI

/// One dynamic-feature card in the Clarity panel: enable toggle, Strength
/// and Sensitivity sliders (each with a reset), a live activity meter, and
/// a one-line help paragraph. Reused for both the linked ("Both ears")
/// card and the stacked per-ear cards — `earLabel` / `tint` drive the
/// header, `ear` selects which processor's activity the meter reads.
struct DynamicFeatureCard: View {
    let kind: DynamicFeatureKind
    @Binding var settings: DynamicFeatureSettings
    /// Which ear's live gain the activity meter reflects.
    let ear: EQBandLookup.Ear
    /// nil → linked card titled by the feature name; otherwise a per-ear
    /// label ("Left ear" / "Right ear").
    var earLabel: String? = nil
    var tint: Color = .accentColor
    var showHelp: Bool = true
    @ObservedObject var activity: DynamicActivityMonitor

    private static let defaults = DynamicFeatureSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            sliderRow(
                label: "Strength",
                systemImage: "dial.high",
                value: $settings.strength,
                defaultValue: Self.defaults.strength,
                help: "How much the feature can change the level."
            )
            sliderRow(
                label: "Sensitivity",
                systemImage: "wave.3.right",
                value: $settings.sensitivity,
                defaultValue: Self.defaults.sensitivity,
                help: "How readily it reacts to the triggering sound."
            )

            activityMeter

            if showHelp {
                Text(kind.helpText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.06))
        )
        .opacity(settings.enabled ? 1.0 : 0.65)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.symbol)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.displayName)
                    .font(.headline)
                if let earLabel {
                    Text(earLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: $settings.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("\(kind.displayName)\(earLabel.map { ", \($0)" } ?? "") enabled")
        }
    }

    // MARK: - Sliders

    @ViewBuilder
    private func sliderRow(
        label: String,
        systemImage: String,
        value: Binding<Double>,
        defaultValue: Double,
        help: String
    ) -> some View {
        HStack(spacing: 10) {
            Label(label, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .frame(minWidth: 110, alignment: .leading)
                .layoutPriority(1)
            Slider(value: value, in: 0...1)
                .tint(tint)
                .controlSize(.small)
                .accessibilityLabel("\(kind.displayName) \(label)\(earLabel.map { ", \($0)" } ?? "")")
                .accessibilityValue("\(Int((value.wrappedValue * 100).rounded())) percent")
            Text("\(Int((value.wrappedValue * 100).rounded())) %")
                .font(.callout.monospaced())
                .frame(minWidth: 48, alignment: .trailing)
            Button {
                value.wrappedValue = defaultValue
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Reset \(label) to default")
            .accessibilityLabel("Reset \(label)")
        }
        .disabled(!settings.enabled)
    }

    // MARK: - Activity meter

    private var currentDelta: Double { activity.gain(kind, ear) }

    private var isActive: Bool { abs(currentDelta) >= 0.1 }

    private var activityMeter: some View {
        // Bar fills from centre toward the cut (left) or boost (right)
        // direction; the number + idle/active text are the non-color
        // redundant encodings (no color-only signaling).
        let span = max(1.0, abs(kind.maxDeltaDB))      // dB at full engage
        let fraction = min(1.0, abs(currentDelta) / span)
        let boosting = kind.direction == .boost

        return HStack(spacing: 10) {
            GeometryReader { geo in
                let w = geo.size.width
                let mid = w / 2
                let half = mid * CGFloat(fraction)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                    // Centre tick.
                    Rectangle()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 1)
                        .position(x: mid, y: geo.size.height / 2)
                    if isActive {
                        Capsule()
                            .fill(tint.opacity(0.8))
                            .frame(width: half)
                            .position(
                                x: boosting ? mid + half / 2 : mid - half / 2,
                                y: geo.size.height / 2
                            )
                    }
                }
            }
            .frame(height: 10)

            HStack(spacing: 6) {
                Text(isActive ? deltaLabel : "idle")
                    .font(.caption.monospaced())
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .frame(minWidth: 64, alignment: .trailing)
            }
        }
        .frame(height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.displayName) activity\(earLabel.map { ", \($0)" } ?? "")")
        .accessibilityValue(accessibilityActivityValue)
    }

    private var deltaLabel: String {
        String(format: "%+.1f dB", currentDelta)
    }

    private var accessibilityActivityValue: String {
        guard isActive else { return "idle" }
        let magnitude = String(format: "%.0f", abs(currentDelta))
        return kind.direction == .boost
            ? "currently boosting \(magnitude) decibels"
            : "currently reducing \(magnitude) decibels"
    }
}
