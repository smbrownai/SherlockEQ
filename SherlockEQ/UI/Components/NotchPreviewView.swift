import SwiftUI

/// A small, self-contained preview of the tinnitus notch's *actual* frequency
/// response — the shaded dip, its center, depth, and width — so the user sees
/// what's being carved out of their audio rather than just a vertical line at
/// the center frequency.
///
/// It draws the identical `TinnitusNotch.asEQBand()` band the audio path uses
/// (via `BiquadResponse`), so the curve can't lie about what the listener
/// hears. When `separate` is on it overlays both ears in their L/R colours so
/// an asymmetric notch is visible at a glance.
struct NotchPreviewView: View {
    var leftNotch: TinnitusNotch
    var rightNotch: TinnitusNotch
    var separate: Bool
    var leftColor: Color = .blue
    var rightColor: Color = .red

    /// Match the Tone Finder rail so the preview lines up with the sweep above.
    private let axis = LogFreqAxis(minHz: 1000, maxHz: 16_000)
    private let maxDB: Double = 3
    private let minDB: Double = -16
    private let freqTicks: [Double] = [1000, 2000, 4000, 8000, 16000]

    /// The traces to draw — enabled notches only. Linked mode collapses to one
    /// purple trace (left == right); separate mode shows each enabled ear.
    private var traces: [Trace] {
        if separate {
            var out: [Trace] = []
            if leftNotch.enabled  { out.append(Trace(notch: leftNotch,  color: leftColor,  tag: "L")) }
            if rightNotch.enabled { out.append(Trace(notch: rightNotch, color: rightColor, tag: "R")) }
            return out
        } else if leftNotch.enabled {
            return [Trace(notch: leftNotch, color: .purple, tag: nil)]
        }
        return []
    }

    private struct Trace: Identifiable {
        let notch: TinnitusNotch
        let color: Color
        let tag: String?
        var id: String { (tag ?? "•") + "\(notch.frequencyHz)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if traces.isEmpty {
                placeholder
            } else {
                canvas
                    .frame(height: 140)
                summary
            }
        }
    }

    // MARK: - Placeholder

    private var placeholder: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path")
                .foregroundStyle(.secondary)
            Text("Turn the notch on to preview the band it reduces.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            Canvas { context, size in
                drawFrame(context, size: size)
                for trace in traces { draw(trace, context: context, size: size) }
                drawFreqLabels(context, size: size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Notch shape preview")
        .accessibilityValue(accessibilitySummary)
    }

    private func drawFrame(_ context: GraphicsContext, size: CGSize) {
        context.fill(
            Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 12),
            with: .color(.secondary.opacity(0.08))
        )
        // 0 dB baseline + a couple of reference gridlines.
        for db in [0.0, -6.0, -12.0] {
            let y = yFor(db, size)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(
                line,
                with: .color(.secondary.opacity(db == 0 ? 0.3 : 0.14)),
                style: StrokeStyle(lineWidth: db == 0 ? 1 : 0.5, dash: db == 0 ? [] : [3, 3])
            )
            let label = Text(db == 0 ? "0 dB" : "\(Int(db))")
                .font(.caption2.monospaced())
                .foregroundColor(.secondary)
            context.draw(label, at: CGPoint(x: 4, y: y - 7), anchor: .topLeading)
        }
    }

    private func draw(_ trace: Trace, context: GraphicsContext, size: CGSize) {
        guard let band = trace.notch.asEQBand() else { return }
        let steps = 260
        var points: [CGPoint] = []
        points.reserveCapacity(steps + 1)
        for i in 0...steps {
            let frac = Double(i) / Double(steps)
            let hz = axis.hz(forFrac: frac)
            let db = BiquadResponse.magnitudeDB(at: hz, band: band)
            points.append(CGPoint(x: CGFloat(frac) * size.width, y: yFor(db, size)))
        }

        // Shade the dip: the curve closed back along the 0 dB baseline.
        let baselineY = yFor(0, size)
        var fill = Path()
        fill.move(to: CGPoint(x: points[0].x, y: baselineY))
        for p in points { fill.addLine(to: p) }
        fill.addLine(to: CGPoint(x: points[points.count - 1].x, y: baselineY))
        fill.closeSubpath()
        context.fill(fill, with: .color(trace.color.opacity(0.14)))

        // Center-frequency marker.
        let cx = axis.x(forHz: band.frequencyHz, width: size.width)
        var center = Path()
        center.move(to: CGPoint(x: cx, y: 0))
        center.addLine(to: CGPoint(x: cx, y: size.height))
        context.stroke(
            center,
            with: .color(trace.color.opacity(0.45)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
        )

        // The response curve on top.
        var line = Path()
        line.addLines(points)
        context.stroke(
            line,
            with: .color(trace.color.opacity(0.95)),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawFreqLabels(_ context: GraphicsContext, size: CGSize) {
        for hz in freqTicks {
            let x = axis.x(forHz: hz, width: size.width)
            let label = Text(hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))")
                .font(.caption2.monospaced())
                .foregroundColor(.secondary)
            context.draw(label, at: CGPoint(x: x, y: size.height - 4), anchor: .bottom)
        }
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(traces) { trace in
                HStack(spacing: 6) {
                    if let tag = trace.tag {
                        Circle().fill(trace.color).frame(width: 8, height: 8)
                        Text(tag == "L" ? "Left" : "Right")
                            .font(.caption.weight(.medium))
                            .frame(width: 40, alignment: .leading)
                    }
                    Text(describe(trace.notch))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func describe(_ notch: TinnitusNotch) -> String {
        "\(Int(notch.frequencyHz).formatted()) Hz  ·  \(Int(notch.depthdB)) dB  ·  \(notch.qWidth.label) (\(notch.qWidth.detail))"
    }

    private var accessibilitySummary: String {
        guard !traces.isEmpty else { return "Notch off" }
        return traces.map { trace in
            let ear = trace.tag.map { $0 == "L" ? "Left " : "Right " } ?? ""
            return "\(ear)notch at \(Int(trace.notch.frequencyHz)) hertz, \(Int(trace.notch.depthdB)) decibels, \(trace.notch.qWidth.label) width"
        }.joined(separator: ". ")
    }

    // MARK: - Geometry

    private func yFor(_ db: Double, _ size: CGSize) -> CGFloat {
        let clamped = max(minDB, min(maxDB, db))
        let frac = (maxDB - clamped) / (maxDB - minDB)
        return CGFloat(frac) * size.height
    }
}
