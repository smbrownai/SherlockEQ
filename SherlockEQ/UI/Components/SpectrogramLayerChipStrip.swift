import SwiftUI

/// Spectrogram-mode layer chips + lens preset menu. Companion to
/// `CanvasLayerChipStrip` (which serves Spectrum mode). Different layer
/// set than the spectrum strip because the heatmap has its own annotation
/// needs (region labels, time axis, color legend, notch line for tinnitus
/// tone-finding, persistence highlighting for sustained tones).
struct SpectrogramLayerChipStrip: View {
    @Binding var showEQCurve: Bool
    @Binding var showNotchLine: Bool
    @Binding var showRegionLabels: Bool
    @Binding var showColorLegend: Bool
    @Binding var showTimeAxis: Bool
    @Binding var showPersistence: Bool

    /// Used as the swatch hue for the EQ chip.
    let earColor: Color
    /// Whether the active profile has an actionable tinnitus notch. When
    /// false the Notch chip is hidden — nothing for it to display.
    let hasNotch: Bool

    /// Local state for the compact-layout layers popover (mirrors the
    /// pattern from CanvasLayerChipStrip — collapses at large Dynamic Type
    /// sizes so the strip never overflows).
    @State private var layersPopoverShown: Bool = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullStrip
            compactStrip
        }
    }

    private var fullStrip: some View {
        HStack(spacing: 8) {
            lensMenu
            Divider().frame(height: 20)
            chip(
                "EQ",
                swatch: earColor,
                isOn: $showEQCurve,
                hint: "Show the active equaliser curve on top of the heatmap."
            )
            if hasNotch {
                chip(
                    "Notch",
                    swatch: Self.notchColor,
                    pattern: .dashed,
                    isOn: $showNotchLine,
                    hint: "Horizontal line at the tinnitus notch frequency — see if the audio has energy at your tinnitus pitch."
                )
            }
            chip(
                "Persistence",
                swatch: Self.persistenceColor,
                isOn: $showPersistence,
                hint: "Outlines frequency bands that have stayed loud for most of the visible history — sustained tones, drones, hum."
            )
            chip(
                "Regions",
                swatch: Self.regionColor,
                isOn: $showRegionLabels,
                hint: "Plain-English y-axis labels: Bass, Low mids, Upper mids, Presence, Air."
            )
            chip(
                "Time",
                swatch: Self.timeColor,
                isOn: $showTimeAxis,
                hint: "Bottom-edge time-ago markers (now, −2s, −4s, …) so you can read how recent each part of the heatmap is."
            )
            chip(
                "Legend",
                swatch: Self.legendColor,
                isOn: $showColorLegend,
                hint: "Color-scale key showing which colours mean quiet vs loud."
            )
            Spacer()
        }
    }

    private var compactStrip: some View {
        HStack(spacing: 8) {
            lensMenu
            Divider().frame(height: 20)
            layersButton
            Spacer()
        }
    }

    // MARK: - Lens menu

    private var lensMenu: some View {
        Menu {
            ForEach(SpectrogramLens.allCases) { lens in
                Button {
                    apply(lens)
                } label: {
                    VStack(alignment: .leading) {
                        Label(lens.label, systemImage: lens.symbol)
                        Text(lens.tagline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("\(lens.label) lens. \(lens.tagline)")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.3.group.bubble")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tint)
                Text("Lens")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tint)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentColor.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch to a curated set of spectrogram overlays for a specific task.")
        .accessibilityLabel("Spectrogram lens preset")
    }

    private func apply(_ lens: SpectrogramLens) {
        showEQCurve       = lens.visibility.eq
        showNotchLine     = lens.visibility.notch
        showRegionLabels  = lens.visibility.regions
        showColorLegend   = lens.visibility.legend
        showTimeAxis      = lens.visibility.time
        showPersistence   = lens.visibility.persistence
    }

    // MARK: - Chip

    private enum SwatchPattern { case solid, dashed }

    private func chip(
        _ label: String,
        swatch: Color,
        pattern: SwatchPattern = .solid,
        isOn: Binding<Bool>,
        hint: String
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn.wrappedValue ? "checkmark" : "circle")
                    .font(.caption.weight(.semibold))
                    .frame(width: 12)
                    .foregroundStyle(isOn.wrappedValue ? swatch : Color.secondary)
                ZStack {
                    Circle()
                        .fill(swatch.opacity(isOn.wrappedValue ? 1.0 : 0.35))
                    Circle()
                        .strokeBorder(
                            Color.white.opacity(0.45),
                            style: StrokeStyle(
                                lineWidth: 1,
                                dash: pattern == .dashed ? [2, 1.5] : []
                            )
                        )
                }
                .frame(width: 12, height: 12)
                Text(label)
                    .font(.callout)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isOn.wrappedValue ? swatch.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(
                        isOn.wrappedValue ? swatch.opacity(0.55) : Color.secondary.opacity(0.35),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hint)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(isOn.wrappedValue ? "on" : "off"))
        .accessibilityHint(Text(hint))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Compact "Layers" button + popover

    private var layersButton: some View {
        Button {
            layersPopoverShown.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.3.group")
                    .font(.callout.weight(.semibold))
                Text("Layers")
                    .font(.callout.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.secondary.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.secondary.opacity(0.40), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show / hide individual spectrogram annotations.")
        .accessibilityLabel("Layers")
        .accessibilityHint("Opens a panel where you can toggle each spectrogram annotation on or off.")
        .popover(isPresented: $layersPopoverShown, arrowEdge: .top) {
            popoverContent
                .padding(16)
                .frame(minWidth: 260)
        }
    }

    @ViewBuilder private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Spectrogram layers")
                .font(.headline)
            popoverRow("EQ curve", swatch: earColor, isOn: $showEQCurve)
            if hasNotch {
                popoverRow("Tinnitus notch line", swatch: Self.notchColor, pattern: .dashed, isOn: $showNotchLine)
            }
            popoverRow("Persistence highlight", swatch: Self.persistenceColor, isOn: $showPersistence)
            popoverRow("Region labels", swatch: Self.regionColor, isOn: $showRegionLabels)
            popoverRow("Time axis", swatch: Self.timeColor, isOn: $showTimeAxis)
            popoverRow("Color legend", swatch: Self.legendColor, isOn: $showColorLegend)
        }
    }

    private func popoverRow(
        _ label: String,
        swatch: Color,
        pattern: SwatchPattern = .solid,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(swatch)
                    Circle().strokeBorder(
                        Color.white.opacity(0.45),
                        style: StrokeStyle(
                            lineWidth: 1,
                            dash: pattern == .dashed ? [2, 1.5] : []
                        )
                    )
                }
                .frame(width: 14, height: 14)
                Text(label)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    // MARK: - Layer colors

    static let notchColor = Color.purple
    static let persistenceColor = Color(red: 1.0, green: 0.78, blue: 0.25)
    static let regionColor = Color(red: 0.55, green: 0.75, blue: 0.92)
    static let timeColor = Color(red: 0.75, green: 0.78, blue: 0.82)
    static let legendColor = Color(red: 0.85, green: 0.65, blue: 0.95)
}

// MARK: - Spectrogram lens presets

/// Curated overlay combinations for common spectrogram workflows.
enum SpectrogramLens: String, CaseIterable, Identifiable {
    case overview, tinnitus, speech, monitoring

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview:   return "Overview"
        case .tinnitus:   return "Tinnitus"
        case .speech:     return "Speech"
        case .monitoring: return "Monitoring"
        }
    }

    var symbol: String {
        switch self {
        case .overview:   return "waveform"
        case .tinnitus:   return "ear"
        case .speech:     return "person.wave.2"
        case .monitoring: return "exclamationmark.shield"
        }
    }

    var tagline: String {
        switch self {
        case .overview:
            return "Default annotated view: regions, time, color legend, EQ on top."
        case .tinnitus:
            return "Find a persistent tone — notch line + persistence highlights, EQ hidden."
        case .speech:
            return "Speech-content focus: regions + time + legend, persistence off."
        case .monitoring:
            return "Watch for sustained loud bands — persistence + legend + time."
        }
    }

    struct Visibility {
        let eq: Bool
        let notch: Bool
        let regions: Bool
        let legend: Bool
        let time: Bool
        let persistence: Bool
    }

    var visibility: Visibility {
        switch self {
        case .overview:
            return .init(eq: true,  notch: false, regions: true, legend: true, time: true, persistence: false)
        case .tinnitus:
            return .init(eq: false, notch: true,  regions: true, legend: false, time: true, persistence: true)
        case .speech:
            return .init(eq: true,  notch: false, regions: true, legend: true, time: true, persistence: false)
        case .monitoring:
            return .init(eq: true,  notch: false, regions: false, legend: true, time: true, persistence: true)
        }
    }
}
