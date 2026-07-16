import SwiftUI
import Charts

/// Interactive audiogram chart for a single ear. X-axis is log-spaced Hz; Y-axis
/// is dB HL inverted (0 at top, 110 at bottom) per audiology convention. The
/// user drags anywhere in the plot to edit the *nearest* audiogram frequency's
/// threshold — they aren't required to grab a specific dot.
struct AudiogramChartView: View {
    @Binding var thresholds: [AudiogramPoint]
    let earColor: Color
    /// False when no audiogram has been entered/imported yet. The points are
    /// still the flat-0 defaults, so they're drawn as hollow ghosts (never a
    /// solid measured line) to avoid presenting missing data as a normal result.
    var entered: Bool = true

    private let yRange: ClosedRange<Double> = 0...110

    var body: some View {
        Chart {
            ForEach(thresholds, id: \.frequencyHz) { point in
                if entered {
                    LineMark(
                        x: .value("Hz", Double(point.frequencyHz)),
                        y: .value("dB HL", point.thresholddBHL)
                    )
                    .foregroundStyle(earColor)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Hz", Double(point.frequencyHz)),
                        y: .value("dB HL", point.thresholddBHL)
                    )
                    .foregroundStyle(earColor)
                    .symbolSize(80)
                } else {
                    PointMark(
                        x: .value("Hz", Double(point.frequencyHz)),
                        y: .value("dB HL", point.thresholddBHL)
                    )
                    .foregroundStyle(earColor.opacity(0.35))
                    .symbol {
                        Circle()
                            .strokeBorder(earColor.opacity(0.5), lineWidth: 1.5)
                            .frame(width: 9, height: 9)
                    }
                }
            }
        }
        .chartXScale(domain: 200...10_000, type: .log)
        .chartXAxis {
            AxisMarks(values: AudiogramPoint.standardFrequencies.map { Double($0) }) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let hz = value.as(Double.self) {
                        Text(formatFrequency(hz))
                            .font(.caption)
                    }
                }
            }
        }
        // Audiology convention: 0 dB HL at the TOP, 110 at the bottom.
        // Reversed by passing the domain as a [high, low] array.
        .chartYScale(domain: [yRange.upperBound, yRange.lowerBound])
        .chartYAxis {
            AxisMarks(values: stride(from: 0, through: 110, by: 20).map { Double($0) }) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))").font(.caption)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(dragGesture(proxy: proxy, geo: geo))
            }
        }
        .overlay {
            if !entered {
                Text("No thresholds entered yet — drag here, use the Listening Check, or import a report.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(minHeight: 220)
        // Replace the chart for VoiceOver / keyboard users with one
        // adjustable Stepper per audiogram frequency. Visual stays as
        // the chart; accessibility users get a labeled, focusable,
        // arrow-key-adjustable stack that respects the same 5 dB snap
        // the drag gesture uses. Without this the chart was entirely
        // invisible to VO and unusable from the keyboard.
        .accessibilityRepresentation { accessibleAudiogram }
    }

    @ViewBuilder private var accessibleAudiogram: some View {
        VStack(alignment: .leading) {
            Text("Audiogram thresholds")
                .font(.headline)
            ForEach(thresholds.indices, id: \.self) { idx in
                Stepper(
                    value: bindingForThreshold(at: idx),
                    in: yRange,
                    step: 5
                ) {
                    Text("\(formatFrequency(Double(thresholds[idx].frequencyHz))) hertz")
                }
                .accessibilityValue("\(Int(thresholds[idx].thresholddBHL)) dB HL")
            }
        }
    }

    /// Binding that survives @Binding<Array> indexing — direct
    /// `$thresholds[idx].thresholddBHL` would fail because the array
    /// indices aren't stable identifiers. Wraps the get/set so the
    /// Stepper can drive a single threshold without confusing Combine.
    private func bindingForThreshold(at index: Int) -> Binding<Double> {
        Binding(
            get: { thresholds[index].thresholddBHL },
            set: { newValue in
                let snapped = (max(yRange.lowerBound, min(yRange.upperBound, newValue)) / 5.0).rounded() * 5.0
                if thresholds[index].thresholddBHL != snapped {
                    thresholds[index].thresholddBHL = snapped
                }
            }
        )
    }

    private func dragGesture(proxy: ChartProxy, geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let plotFrame = proxy.plotFrame else { return }
                let frame = geo[plotFrame]
                let localX = value.location.x - frame.origin.x
                let localY = value.location.y - frame.origin.y

                guard let hzAtCursor: Double = proxy.value(atX: localX) else { return }
                guard let dbhlAtCursor: Double = proxy.value(atY: localY) else { return }

                let nearest = AudiogramPoint.standardFrequencies.min { a, b in
                    abs(Double(a) - hzAtCursor) < abs(Double(b) - hzAtCursor)
                }
                guard let nearestHz = nearest else { return }

                let clamped = max(yRange.lowerBound, min(yRange.upperBound, dbhlAtCursor))
                let rounded = (clamped / 5.0).rounded() * 5.0    // snap to 5 dB steps

                if let idx = thresholds.firstIndex(where: { $0.frequencyHz == nearestHz }) {
                    if thresholds[idx].thresholddBHL != rounded {
                        thresholds[idx].thresholddBHL = rounded
                    }
                }
            }
    }

    private func formatFrequency(_ hz: Double) -> String {
        if hz >= 1000 {
            let k = hz / 1000
            return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return "\(Int(hz))"
    }
}
