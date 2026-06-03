import SwiftUI
import Charts

/// Read-only preview of the EQ bands derived from an audiogram. Visualises
/// what the chain will sound like with the current `compensationFactor`.
struct EQPreviewView: View {
    let leftBands: [EQBand]
    let rightBands: [EQBand]
    let compensationFactor: Double

    private var maxGain: Double {
        let allGains = (leftBands + rightBands).map(\.gaindB)
        return max(AudiogramConversion.perBandCeilingDB, allGains.max() ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            chart
            footnote
        }
    }

    private var header: some View {
        HStack {
            Text("Derived EQ preview").font(.subheadline.weight(.semibold))
            Spacer()
            Text(String(format: "Compensation %.0f%%", compensationFactor * 100))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(Array(leftBands.enumerated()), id: \.offset) { _, band in
                LineMark(
                    x: .value("Hz", band.frequencyHz),
                    y: .value("Gain dB", band.gaindB),
                    series: .value("Ear", "L")
                )
                .foregroundStyle(.blue)
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("Hz", band.frequencyHz),
                    y: .value("Gain dB", band.gaindB)
                )
                .foregroundStyle(.blue)
                .symbolSize(36)
            }

            ForEach(Array(rightBands.enumerated()), id: \.offset) { _, band in
                LineMark(
                    x: .value("Hz", band.frequencyHz),
                    y: .value("Gain dB", band.gaindB),
                    series: .value("Ear", "R")
                )
                .foregroundStyle(.red)
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("Hz", band.frequencyHz),
                    y: .value("Gain dB", band.gaindB)
                )
                .foregroundStyle(.red)
                .symbolSize(36)
            }
        }
        .chartXScale(domain: 200...10_000, type: .log)
        .chartXAxis {
            AxisMarks(values: AudiogramPoint.standardFrequencies.map { Double($0) }) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let hz = value.as(Double.self) {
                        Text(formatFrequency(hz)).font(.caption2)
                    }
                }
            }
        }
        .chartYScale(domain: 0...maxGain)
        .chartYAxis {
            AxisMarks(values: stride(from: 0, through: maxGain, by: 5).map { $0 }) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))").font(.caption2)
                    }
                }
            }
        }
        .frame(height: 140)
    }

    private var footnote: some View {
        HStack(spacing: 14) {
            legendDot(.blue, label: "Left")
            legendDot(.red, label: "Right")
            Spacer()
            Text("Per-band ceiling: \(Int(AudiogramConversion.perBandCeilingDB)) dB")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func legendDot(_ color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption)
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
