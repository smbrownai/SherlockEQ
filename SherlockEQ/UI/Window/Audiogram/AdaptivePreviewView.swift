import SwiftUI
import Charts

/// Level-aware preview for the Adaptive correction style
/// (phase4-adaptive-correction.md §6.2) — the "drawn = heard" answer to
/// "what does Adaptive actually do?".
///
/// Draws the correction **family** for one ear: three curves at 50 / 65 /
/// 85 dB SPL input (quiet / moderate / loud), each the §1 prescription's
/// six band gains rendered through the filterbank's own composite-response
/// evaluator, summed with the user/preset EQ's biquad composite. The
/// 65 dB curve is emphasized — it equals the Steady curve by construction
/// (the prescription anchors there). Pure math; no DSP involved.
struct AdaptivePreviewView: View {
    @EnvironmentObject private var audioState: AudioState

    /// The displayed ear's audiogram thresholds (drives per-band CR).
    let thresholds: [AudiogramPoint]
    /// FULL-STRENGTH stored correction bands (the Phase-3 contract) —
    /// strength is applied here at consumption time, like the engine does.
    let correctionBands: [EQBand]
    /// The ear's user/preset EQ bands — in Adaptive mode these still run in
    /// the static cascade, so the heard result includes them.
    let userBands: [EQBand]
    /// Effective strength (target × acclimatization ramp) — drives the curves.
    let strength: Double
    /// The user's strength dial, for the header label only.
    let targetStrength: Double
    let earLabel: String
    let earColor: Color

    private let minHz: Double = 20
    private let maxHz: Double = 20_000
    private let sampleCount: Int = 160

    /// The preview families, quiet → loud. `emphasized` marks the 65 dB
    /// anchor curve (== Steady).
    private struct Family: Identifiable {
        let id: Double        // input SPL
        let label: String
        let emphasized: Bool
    }
    private static let families: [Family] = [
        Family(id: 50, label: "Quiet (50 dB)", emphasized: false),
        Family(id: 65, label: "Moderate (65 dB)", emphasized: true),
        Family(id: 85, label: "Loud (85 dB)", emphasized: false),
    ]

    private struct SamplePoint: Hashable {
        let hz: Double
        let dB: Double
        let series: String
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
            Text("Adaptive preview").font(.subheadline.weight(.semibold))
            Text("— \(earLabel), by input level")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(AdjustmentStrengthLabel.text(target: targetStrength, effective: strength))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        let curves = Self.families.map { family in
            (family: family, points: samples(inputSPL: family.id, label: family.label))
        }
        let allDB = curves.flatMap { $0.points.map(\.dB) }
        let upper = max(6, ceil((allDB.max() ?? 0) / 6) * 6)
        let lower = min(-6, floor((allDB.min() ?? 0) / 6) * 6)
        return Chart {
            ForEach(curves, id: \.family.id) { curve in
                ForEach(curve.points, id: \.self) { p in
                    LineMark(
                        x: .value("Hz", p.hz),
                        y: .value("Gain dB", p.dB),
                        series: .value("Level", p.series)
                    )
                    .foregroundStyle(earColor.opacity(curve.family.emphasized ? 1.0 : 0.45))
                    .lineStyle(StrokeStyle(lineWidth: curve.family.emphasized ? 2.2 : 1.2))
                }
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
        .chartYScale(domain: lower...upper)
        .chartYAxis {
            AxisMarks(values: stride(from: lower, through: upper, by: 6).map { $0 }) { value in
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
            legendLine(opacity: 0.45, label: "Quiet — more help")
            legendLine(opacity: 1.0, label: "Moderate — the Steady curve")
            legendLine(opacity: 0.45, label: "Loud — less help")
            Spacer()
        }
    }

    private func legendLine(opacity: Double, label: String) -> some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(earColor.opacity(opacity))
                .frame(width: 14, height: opacity == 1.0 ? 3 : 2)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func formatFrequency(_ hz: Double) -> String {
        if hz >= 1000 {
            let k = hz / 1000
            return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return "\(Int(hz))"
    }

    /// One family curve: the prescription's six gains at this input level,
    /// composed through the filterbank response, plus the user EQ composite.
    /// Mirrors the engine's Adaptive chain (adaptive stage + static user
    /// bands) so the drawn family is what the listener hears.
    private func samples(inputSPL: Double, label: String) -> [SamplePoint] {
        let params = AdaptiveCorrectionPrescription.bandParameters(
            thresholds: thresholds,
            correctionBands: correctionBands
        )
        let gains = params.map {
            AdaptiveCorrectionPrescription.gainDB(
                band: $0,
                inputSPL: inputSPL,
                strength: strength,
                calibrated: audioState.hasUserCalibration
            )
        }
        let sr = audioState.audio.outputSampleRate ?? 48_000
        let axis = LogFreqAxis(minHz: minHz, maxHz: maxHz)
        return (0..<sampleCount).map { i in
            let frac = Double(i) / Double(sampleCount - 1)
            let hz = axis.hz(forFrac: frac)
            let dB = AdaptiveFilterbank.compositeMagnitudeDB(atHz: hz, gainsDB: gains, sampleRate: sr)
                + BiquadResponse.compositeMagnitudeDB(at: hz, bands: userBands)
            return SamplePoint(hz: hz, dB: dB, series: label)
        }
    }
}
