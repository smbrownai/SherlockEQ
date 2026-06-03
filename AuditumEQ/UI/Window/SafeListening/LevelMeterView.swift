import SwiftUI

/// Live A-weighted level meter with color zones aligned to typical safety
/// breakpoints (≤70 unlimited, 70–85 cautious, 85–95 NIOSH limit, ≥95 risky).
struct LevelMeterView: View {
    let levelDBA: Double

    private let minDB: Double = 30
    private let maxDB: Double = 110

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(displayValue)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("dBA")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
                Label(zoneLabel, systemImage: zoneSymbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(zoneColor)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)

                    Capsule()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .green,  location: 0),
                                    .init(color: .green,  location: locationFor(70)),
                                    .init(color: .yellow, location: locationFor(70.01)),
                                    .init(color: .yellow, location: locationFor(85)),
                                    .init(color: .orange, location: locationFor(85.01)),
                                    .init(color: .orange, location: locationFor(95)),
                                    .init(color: .red,    location: locationFor(95.01)),
                                    .init(color: .red,    location: 1),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, geo.size.width * fillFraction))
                        .animation(.easeOut(duration: 0.15), value: fillFraction)

                    ForEach([70, 85, 95], id: \.self) { marker in
                        Rectangle()
                            .fill(Color.primary.opacity(0.25))
                            .frame(width: 1)
                            .offset(x: geo.size.width * locationFor(Double(marker)))
                    }
                }
            }
            .frame(height: 14)

            HStack {
                Text("\(Int(minDB))")
                Spacer()
                Text("70")
                Spacer()
                Text("85")
                Spacer()
                Text("95")
                Spacer()
                Text("\(Int(maxDB))")
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
        }
    }

    private var fillFraction: Double {
        let clamped = max(minDB, min(maxDB, levelDBA))
        return (clamped - minDB) / (maxDB - minDB)
    }

    private func locationFor(_ dB: Double) -> CGFloat {
        let clamped = max(minDB, min(maxDB, dB))
        return CGFloat((clamped - minDB) / (maxDB - minDB))
    }

    private var displayValue: String {
        if levelDBA < minDB + 1 { return "—" }
        return String(format: "%.0f", levelDBA)
    }

    private var zoneLabel: String {
        switch levelDBA {
        case ..<70:  return "Safe"
        case ..<85:  return "Moderate"
        case ..<95:  return "Loud"
        default:     return "Very loud"
        }
    }

    private var zoneSymbol: String {
        switch levelDBA {
        case ..<70:  return "checkmark.shield.fill"
        case ..<85:  return "ear"
        case ..<95:  return "exclamationmark.triangle.fill"
        default:     return "exclamationmark.octagon.fill"
        }
    }

    private var zoneColor: Color {
        switch levelDBA {
        case ..<70:  return .green
        case ..<85:  return .yellow
        case ..<95:  return .orange
        default:     return .red
        }
    }
}
