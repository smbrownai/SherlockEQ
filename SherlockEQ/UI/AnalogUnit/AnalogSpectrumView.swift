import SwiftUI

/// Layout constants shared between the Analog Control Unit view (which owns
/// the disclosure state) and AppDelegate (which sizes the window).
enum AnalogSpectrumConfig {
    static let collapsedHeight: CGFloat = 400
    static let expandedHeight: CGFloat  = 600   // +50%
    static let expandedKey = "sherlockeq.analogControlUnit.spectrumExpanded"
}

/// A vintage rack spectrum analyzer — the "Bars" view from the Expert EQ,
/// spectrum only (no EQ curve). Reads `audioState.spectrum` (post-EQ) and
/// draws 31 ISO ⅓-octave bars with LED-segment shading, peak-hold caps, and
/// a frequency label under each bar. Colourable green or "colorful" (the
/// same per-region palette the Expert canvas uses), dimmable, sensitivity-
/// scaled, and switchable between full bars and a moving top tick.
struct AnalogSpectrumBars: View {
    @ObservedObject var spectrum: SpectrumAnalyzer
    var colorful: Bool
    var dimmer: Double          // 0…1 brightness
    var sensitivityDB: Double   // dB offset added before display
    var peakOnly: Bool          // tick-only vs full bar

    // ISO 1/3-octave centres, 20 Hz … 20 kHz — same set the Expert bars use.
    private static let centers: [Double] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200,
        250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000,
        2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000,
    ]
    private static let minDB: Double = -90
    private static let maxDB: Double = -6
    private static let barFactor = pow(2.0, 1.0 / 6.0)   // ±1/6 octave window
    private static let logMin = log10(20.0)
    private static let logMax = log10(20000.0)
    private static let green = Color(red: 0.22, green: 0.92, blue: 0.38)

    var body: some View {
        Canvas(rendersAsynchronously: true) { ctx, size in
            draw(ctx, size: size)
        }
        .onAppear { spectrum.subscribe() }
        .onDisappear { spectrum.unsubscribe() }
        .accessibilityLabel("Spectrum analyzer")
        .accessibilityValue(peakOnly ? "peak tick mode" : "bar mode")
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize) {
        let bins = spectrum.logSpectrumDB
        let holds = spectrum.logSpectrumPeakHoldDB
        let n = bins.count
        guard n > 0 else { return }

        let labelH: CGFloat = 13
        let top: CGFloat = 4
        let baseline = size.height - labelH
        guard baseline > top else { return }

        let pad: CGFloat = 2
        let gap: CGFloat = 2
        let count = Self.centers.count
        let step = (size.width - 2 * pad) / CGFloat(count)
        let barW = max(1, step - gap)
        let dim = max(0.15, min(1.0, dimmer))

        // Dark horizontal LED-segment grid lines (every 3 dB) for the
        // stacked-block look.
        let segSteps = Array(stride(from: Self.minDB + 3, through: Self.maxDB, by: 3))

        for (i, center) in Self.centers.enumerated() {
            let x = pad + CGFloat(i) * step + gap / 2
            let loB = bucket(center / Self.barFactor, count: n)
            let hiB = bucket(center * Self.barFactor, count: n)

            var levelDB = Double(Self.minDB)
            var holdDB = Double(Self.minDB)
            for b in loB...hiB {
                levelDB = max(levelDB, Double(bins[b]))
                if b < holds.count { holdDB = max(holdDB, Double(holds[b])) }
            }
            levelDB += sensitivityDB
            holdDB += sensitivityDB

            let levelY = y(levelDB, top: top, baseline: baseline)
            let color = colorful ? Self.semanticColor(center) : Self.green

            if peakOnly {
                // Just the moving top tick.
                let tick = CGRect(x: x, y: levelY - 1.25, width: barW, height: 2.5)
                ctx.fill(Path(tick), with: .color(color.opacity(dim)))
            } else {
                // Full bar with a top-translucent → bottom-opaque gradient.
                let barH = baseline - levelY
                if barH > 0 {
                    let rect = CGRect(x: x, y: levelY, width: barW, height: barH)
                    ctx.fill(
                        Path(rect),
                        with: .linearGradient(
                            Gradient(stops: [
                                .init(color: color.opacity(0.30 * dim), location: 0),
                                .init(color: color.opacity(0.70 * dim), location: 0.55),
                                .init(color: color.opacity(1.00 * dim), location: 1),
                            ]),
                            startPoint: CGPoint(x: rect.midX, y: levelY),
                            endPoint: CGPoint(x: rect.midX, y: baseline)
                        )
                    )
                    // LED-segment dividers carve the bar into blocks.
                    for refDB in segSteps {
                        let sy = y(refDB, top: top, baseline: baseline)
                        guard sy > rect.minY, sy < rect.maxY else { continue }
                        let slice = CGRect(x: x, y: sy - 0.5, width: barW, height: 1)
                        ctx.fill(Path(slice), with: .color(.black.opacity(0.7)))
                    }
                }
                // Peak-hold cap.
                let capY = y(holdDB, top: top, baseline: baseline)
                if capY < baseline {
                    let cap = CGRect(x: x, y: capY - 1, width: barW, height: 1.5)
                    ctx.fill(Path(cap), with: .color(color.opacity(min(1, 0.9 * dim + 0.1))))
                }
            }

            // Frequency label.
            let text = Text(Self.label(center))
                .font(.system(size: 5.5, weight: .medium, design: .monospaced))
                .foregroundStyle(AnalogTheme.engraveDim)
            ctx.draw(text, at: CGPoint(x: x + barW / 2, y: size.height - labelH / 2 + 1), anchor: .center)
        }
    }

    private func y(_ db: Double, top: CGFloat, baseline: CGFloat) -> CGFloat {
        let c = max(Self.minDB, min(Self.maxDB, db))
        let f = (c - Self.minDB) / (Self.maxDB - Self.minDB)
        return baseline - CGFloat(f) * (baseline - top)
    }

    private func bucket(_ hz: Double, count: Int) -> Int {
        let f = (log10(hz) - Self.logMin) / (Self.logMax - Self.logMin)
        return max(0, min(count - 1, Int((Double(count) * f).rounded(.down))))
    }

    /// The Expert canvas's seven semantic-region colours, replicated so the
    /// analog spectrum is self-contained.
    private static func semanticColor(_ hz: Double) -> Color {
        switch hz {
        case ..<60:    return Color(red: 0.40, green: 0.40, blue: 0.85)   // sub-bass
        case ..<250:   return Color(red: 0.30, green: 0.55, blue: 0.92)   // bass
        case ..<500:   return Color(red: 0.20, green: 0.78, blue: 0.85)   // low mids
        case ..<1500:  return Color(red: 0.25, green: 0.85, blue: 0.50)   // vocal body
        case ..<4000:  return Color(red: 0.60, green: 0.90, blue: 0.30)   // clarity
        case ..<8000:  return Color(red: 1.00, green: 0.78, blue: 0.25)   // sibilance
        default:       return Color(red: 0.62, green: 0.85, blue: 0.96)   // air
        }
    }

    private static func label(_ hz: Double) -> String {
        if hz < 1000 { return "\(Int(hz.rounded()))" }
        let k = hz / 1000
        if k >= 10 { return "\(Int(k.rounded()))k" }
        return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
    }
}

// MARK: - Spectrum controls

/// Shared vintage vertical pill cap (22×34) — the common shape for the output
/// selector, the colour toggle, and the peak toggle. Raised silver when off;
/// depressed dark with a lit amber lamp when on. The icon/label always sits
/// *underneath* the cap, never on it.
struct AnalogPillCap: View {
    var isActive: Bool

    static let capW: CGFloat = 22
    static let capH: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.capW / 2 + 2, style: .continuous)
                .fill(Color.black.opacity(0.5))
                .frame(width: Self.capW + 4, height: Self.capH + 4)
                .blur(radius: 1.5)
                .offset(y: 1)

            RoundedRectangle(cornerRadius: Self.capW / 2, style: .continuous)
                .fill(isActive ? AnalogTheme.buttonPressed : AnalogTheme.buttonRaised)
                .frame(width: Self.capW, height: Self.capH)
                .overlay(
                    RoundedRectangle(cornerRadius: Self.capW / 2, style: .continuous)
                        .strokeBorder(AnalogTheme.rim, lineWidth: 1)
                )
                .overlay(alignment: .top) {
                    if isActive {
                        Circle()
                            .fill(AnalogTheme.amber)
                            .frame(width: 5, height: 5)
                            .shadow(color: AnalogTheme.amber.opacity(0.9), radius: 3)
                            .padding(.top, 6)
                    } else {
                        Ellipse()
                            .fill(Color.white.opacity(0.4))
                            .frame(width: Self.capW * 0.55, height: 4)
                            .padding(.top, 3)
                            .blur(radius: 1.5)
                    }
                }
                .shadow(color: .black.opacity(isActive ? 0.6 : 0.4),
                        radius: isActive ? 1 : 3,
                        y: isActive ? 0 : 2)
        }
        .frame(width: Self.capW + 4, height: Self.capH + 4)
    }
}

/// Toggles the bars between all-green and the colourful per-region palette.
/// Same pill size as the output selector; the cap shows the current mode
/// (green vs a rainbow) with a "COLOR" label underneath.
struct AnalogColorPill: View {
    @Binding var colorful: Bool

    private static let rainbow = LinearGradient(
        colors: [
            Color(red: 0.30, green: 0.55, blue: 0.92),
            Color(red: 0.25, green: 0.85, blue: 0.50),
            Color(red: 0.60, green: 0.90, blue: 0.30),
            Color(red: 1.00, green: 0.78, blue: 0.25),
        ],
        startPoint: .bottom, endPoint: .top
    )

    var body: some View {
        Button {
            colorful.toggle()
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: AnalogPillCap.capW / 2 + 2, style: .continuous)
                        .fill(Color.black.opacity(0.5))
                        .frame(width: AnalogPillCap.capW + 4, height: AnalogPillCap.capH + 4)
                        .blur(radius: 1.5)
                        .offset(y: 1)
                    RoundedRectangle(cornerRadius: AnalogPillCap.capW / 2, style: .continuous)
                        .fill(colorful ? AnyShapeStyle(Self.rainbow)
                                       : AnyShapeStyle(Color(red: 0.22, green: 0.92, blue: 0.38)))
                        .frame(width: AnalogPillCap.capW, height: AnalogPillCap.capH)
                        .overlay(
                            RoundedRectangle(cornerRadius: AnalogPillCap.capW / 2, style: .continuous)
                                .strokeBorder(AnalogTheme.rim, lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
                }
                .frame(width: AnalogPillCap.capW + 4, height: AnalogPillCap.capH + 4)

                Text("COLOR")
                    .font(.system(size: 7, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(AnalogTheme.engraveDim)
            }
        }
        .buttonStyle(.plain)
        .help(colorful ? "Colourful bars — tap for green" : "Green bars — tap for colourful")
        .accessibilityLabel("Bar colour")
        .accessibilityValue(colorful ? "colourful" : "green")
    }
}

/// A latching pill push button with its label underneath — same pill size as
/// the output selector. Lit (amber lamp, depressed) when on.
struct AnalogToggleButton: View {
    @Binding var isOn: Bool
    let label: String
    var accessibilityName: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            VStack(spacing: 4) {
                AnalogPillCap(isActive: isOn)
                Text(label)
                    .font(.system(size: 7, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(isOn ? AnalogTheme.cream : AnalogTheme.engraveDim)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(isOn ? "on" : "off")
    }
}
