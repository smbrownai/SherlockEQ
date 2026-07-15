import SwiftUI
import Charts

/// Read-only preview of the active profile's full EQ chain.
///
/// Computes the *actual* composite biquad response at sampled frequencies
/// across the full audible range (20 Hz – 20 kHz), so it visualises every
/// band — audiogram-derived, Simple shelves, Advanced sliders, Expert
/// drags, all of it — as one smooth curve per ear. Same math the
/// Equalizer canvas uses.
struct EQPreviewView: View {
    @EnvironmentObject private var audioState: AudioState

    let leftBands: [EQBand]
    let rightBands: [EQBand]
    let compensationFactor: Double

    private let minHz: Double = 20
    private let maxHz: Double = 20_000
    private let sampleCount: Int = 200

    private struct SamplePoint: Hashable {
        let hz: Double
        let dB: Double
        let ear: String
    }

    private var leftSamples: [SamplePoint] {
        Self.samples(bands: leftBands, label: "L", minHz: minHz, maxHz: maxHz, count: sampleCount)
    }
    private var rightSamples: [SamplePoint] {
        Self.samples(bands: rightBands, label: "R", minHz: minHz, maxHz: maxHz, count: sampleCount)
    }

    private var yRange: ClosedRange<Double> {
        let all = (leftSamples + rightSamples).map(\.dB)
        let maxV = max(6, ceil((all.max() ?? 0) / 6) * 6)
        let minV = min(-6, floor((all.min() ?? 0) / 6) * 6)
        return minV...maxV
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
            Text("EQ preview").font(.subheadline.weight(.semibold))
            Text("— your full result, both ears")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "Compensation %.0f%%", compensationFactor * 100))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(leftSamples, id: \.self) { p in
                LineMark(
                    x: .value("Hz", p.hz),
                    y: .value("Gain dB", p.dB),
                    series: .value("Ear", p.ear)
                )
                .foregroundStyle(audioState.preferences.leftEarColor)
            }
            ForEach(rightSamples, id: \.self) { p in
                LineMark(
                    x: .value("Hz", p.hz),
                    y: .value("Gain dB", p.dB),
                    series: .value("Ear", p.ear)
                )
                .foregroundStyle(audioState.preferences.rightEarColor)
            }
        }
        .chartXScale(domain: minHz...maxHz, type: .log)
        .chartXAxis {
            AxisMarks(values: [50.0, 100, 500, 1000, 5000, 10000, 20000]) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let hz = value.as(Double.self) {
                        Text(formatFrequency(hz)).font(.caption)
                    }
                }
            }
        }
        .chartYScale(domain: yRange)
        .chartYAxis {
            AxisMarks(values: stride(from: yRange.lowerBound, through: yRange.upperBound, by: 6).map { $0 }) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(v == 0 ? "0" : String(format: "%+.0f", v))
                            .font(.caption)
                    }
                }
            }
        }
        .frame(height: 140)
    }

    private var footnote: some View {
        HStack(spacing: 14) {
            legendDot(audioState.preferences.leftEarColor, label: "Left")
            legendDot(audioState.preferences.rightEarColor, label: "Right")
            Spacer()
            Text("Per-band ceiling: \(Int(AudiogramConversion.perBandCeilingDB)) dB")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    /// Sample the composite biquad response at log-spaced frequencies.
    private static func samples(
        bands: [EQBand],
        label: String,
        minHz: Double,
        maxHz: Double,
        count: Int
    ) -> [SamplePoint] {
        guard count > 1 else { return [] }
        let axis = LogFreqAxis(minHz: minHz, maxHz: maxHz)
        return (0..<count).map { i in
            let frac = Double(i) / Double(count - 1)
            let hz = axis.hz(forFrac: frac)
            let dB = BiquadResponse.compositeMagnitudeDB(at: hz, bands: bands)
            return SamplePoint(hz: hz, dB: dB, ear: label)
        }
    }
}
