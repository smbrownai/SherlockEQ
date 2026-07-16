import SwiftUI

/// Compact numeric editor for an ear's audiogram thresholds. Eight rows, one
/// per standard frequency, each with a stepper bound to dB HL. Edits feed back
/// into the same binding the chart uses, so chart and editor stay in lockstep.
struct ThresholdEditor: View {
    @Binding var thresholds: [AudiogramPoint]
    let earColor: Color
    /// False until an audiogram has been entered/imported. While false the
    /// severity column reads "Not entered" rather than classifying the flat-0
    /// defaults as "Normal". Editing any row stamps the audiogram as entered.
    var entered: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Hz")
                    .frame(width: 60, alignment: .leading)
                Text("dB HL")
                    .frame(width: 64, alignment: .leading)
                Text("Severity")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            Divider()

            ForEach(Array(thresholds.indices), id: \.self) { idx in
                ThresholdRow(
                    threshold: $thresholds[idx],
                    earColor: earColor,
                    entered: entered
                )
            }
        }
    }
}

private struct ThresholdRow: View {
    @Binding var threshold: AudiogramPoint
    let earColor: Color
    var entered: Bool = true

    var body: some View {
        HStack {
            Text(formattedFrequency)
                .font(.callout.monospaced())
                .frame(width: 60, alignment: .leading)

            HStack(spacing: 4) {
                Stepper(
                    value: Binding(
                        get: { threshold.thresholddBHL },
                        set: { threshold.thresholddBHL = max(0, min(110, $0)) }
                    ),
                    in: 0...110,
                    step: 5
                ) {
                    Text("\(Int(threshold.thresholddBHL))")
                        .font(.callout.monospaced())
                }
                .labelsHidden()
                Text("\(Int(threshold.thresholddBHL))")
                    .font(.callout.monospaced())
                    .frame(width: 28, alignment: .trailing)
            }
            .frame(width: 110, alignment: .leading)

            severityBar
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var formattedFrequency: String {
        let hz = threshold.frequencyHz
        if hz >= 1000 {
            let k = Double(hz) / 1000
            return k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
        }
        return "\(hz) Hz"
    }

    private var severityCategory: String {
        switch threshold.thresholddBHL {
        case ..<25:  return "Normal"
        case ..<40:  return "Mild"
        case ..<55:  return "Moderate"
        case ..<70:  return "Mod. severe"
        case ..<90:  return "Severe"
        default:     return "Profound"
        }
    }

    private var severityTint: Color {
        switch threshold.thresholddBHL {
        case ..<25:  return .green
        case ..<40:  return .yellow
        case ..<55:  return .orange
        case ..<70:  return .red.opacity(0.8)
        case ..<90:  return .red
        default:     return .purple
        }
    }

    private var severityBar: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    if entered {
                        Capsule()
                            .fill(severityTint)
                            .frame(width: geo.size.width * (threshold.thresholddBHL / 110))
                    }
                }
            }
            .frame(height: 6)
            Text(entered ? severityCategory : "Not entered")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
        }
    }
}
