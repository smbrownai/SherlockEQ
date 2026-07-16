import SwiftUI

/// One Adaptive Comfort card. Collapsed (off) it's just an icon, a plain
/// title + subtitle, and a switch — so a page of them reads as available
/// toggles, not a greyed-out dead panel. Enabling it reveals a single
/// primary **Amount** slider, an ordinary-language status line, and an
/// **Advanced** disclosure holding Sensitivity. Reused for the linked
/// ("both ears") card and the stacked per-ear cards — `earLabel` / `tint`
/// drive the header, `ear` selects which processor's activity the status
/// reads.
struct DynamicFeatureCard: View {
    let kind: DynamicFeatureKind
    @Binding var settings: DynamicFeatureSettings
    /// Which ear's live gain the status line reflects.
    let ear: EQBandLookup.Ear
    /// nil → linked card titled by the feature name; otherwise a per-ear
    /// label ("Left ear" / "Right ear").
    var earLabel: String? = nil
    var tint: Color = .accentColor
    @ObservedObject var activity: DynamicActivityMonitor

    @State private var showAdvanced = false
    private static let defaults = DynamicFeatureSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if settings.enabled {
                amountRow
                statusRow
                advancedDisclosure
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(settings.enabled ? tint.opacity(0.08) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(settings.enabled ? tint.opacity(0.15) : .clear, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.18), value: settings.enabled)
    }

    // MARK: - Header (always visible)

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.title3)
                .foregroundStyle(settings.enabled ? tint : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kind.comfortName)
                        .font(.headline)
                    if let earLabel {
                        Text(earLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(kind.comfortSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $settings.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("\(kind.comfortName)\(earLabel.map { ", \($0)" } ?? "")")
        }
    }

    // MARK: - Amount (the one primary control)

    private var amountRow: some View {
        HStack(spacing: 10) {
            Label("Amount", systemImage: "dial.high")
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .frame(minWidth: 96, alignment: .leading)
                .layoutPriority(1)
            Slider(value: $settings.strength, in: 0...1)
                .tint(tint)
                .controlSize(.small)
                .accessibilityLabel("\(kind.comfortName) amount\(earLabel.map { ", \($0)" } ?? "")")
                .accessibilityValue("\(pct(settings.strength)) percent")
            Text("\(pct(settings.strength)) %")
                .font(.callout.monospaced())
                .frame(minWidth: 48, alignment: .trailing)
            Button {
                settings.strength = Self.defaults.strength
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Reset Amount to default")
            .accessibilityLabel("Reset Amount")
        }
    }

    // MARK: - Status line (ordinary-language feedback)

    private var currentDelta: Double { activity.gain(kind, ear) }
    private var isActive: Bool { abs(currentDelta) >= 0.1 }

    private var statusRow: some View {
        let span = max(1.0, abs(kind.maxDeltaDB))
        let fraction = min(1.0, abs(currentDelta) / span)
        let boosting = kind.direction == .boost
        return HStack(spacing: 10) {
            GeometryReader { geo in
                let w = geo.size.width
                let mid = w / 2
                let half = mid * CGFloat(fraction)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Rectangle()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 1)
                        .position(x: mid, y: geo.size.height / 2)
                    if isActive {
                        Capsule()
                            .fill(tint.opacity(0.85))
                            .frame(width: half)
                            .position(
                                x: boosting ? mid + half / 2 : mid - half / 2,
                                y: geo.size.height / 2
                            )
                    }
                }
            }
            .frame(width: 90, height: 8)

            Text(isActive ? kind.activeStatus : kind.idleStatus)
                .font(.callout)
                .foregroundStyle(isActive ? tint : .secondary)
            Spacer()
        }
        .frame(height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.comfortName) status\(earLabel.map { ", \($0)" } ?? "")")
        .accessibilityValue(isActive ? kind.activeStatus : kind.idleStatus)
    }

    // MARK: - Advanced disclosure (Sensitivity)

    private var advancedDisclosure: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            HStack(spacing: 10) {
                Label("Sensitivity", systemImage: "wave.3.right")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                    .frame(minWidth: 96, alignment: .leading)
                    .layoutPriority(1)
                Slider(value: $settings.sensitivity, in: 0...1)
                    .tint(tint)
                    .controlSize(.small)
                    .accessibilityLabel("\(kind.comfortName) sensitivity\(earLabel.map { ", \($0)" } ?? "")")
                    .accessibilityValue("\(pct(settings.sensitivity)) percent")
                Text("\(pct(settings.sensitivity)) %")
                    .font(.callout.monospaced())
                    .frame(minWidth: 48, alignment: .trailing)
                Button {
                    settings.sensitivity = Self.defaults.sensitivity
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Reset Sensitivity to default")
                .accessibilityLabel("Reset Sensitivity")
            }
            .padding(.top, 4)
            Text("How readily it reacts to the triggering sound.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Advanced")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private func pct(_ v: Double) -> Int { Int((v * 100).rounded()) }
}
