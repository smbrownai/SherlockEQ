import SwiftUI
import Charts

/// Interactive audiogram chart for a single ear. X-axis is log-spaced Hz; Y-axis
/// is dB HL inverted (0 at top, 110 at bottom) per audiology convention. The
/// user drags anywhere in the plot to edit the *nearest* audiogram frequency's
/// threshold — they aren't required to grab a specific dot.
struct AudiogramChartView: View {
    @Binding var thresholds: [AudiogramPoint]
    let earColor: Color

    private let yRange: ClosedRange<Double> = 0...110

    var body: some View {
        Chart {
            ForEach(thresholds, id: \.frequencyHz) { point in
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
        .frame(minHeight: 220)
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
