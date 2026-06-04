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

            // Canvas-based rendering — more reliable than ZStack with
            // conditional Rectangle + .offset for absolute-positioned
            // bars. Each zone is its own filled rectangle at fixed
            // pixel coordinates, drawn left to right in order. The
            // capsule clip is applied to the whole canvas after drawing.
            Canvas { ctx, size in
                // Background capsule fill.
                let bgPath = Path(roundedRect: CGRect(origin: .zero, size: size),
                                  cornerRadius: size.height / 2)
                ctx.fill(bgPath, with: .color(.secondary.opacity(0.18)))

                // Each zone: only draws when the level has reached into
                // it. A 60 dBA reading shows ONLY the green segment;
                // 90 dBA adds yellow and the start of orange; 105 dBA
                // (the user's screenshot) adds the red section at the
                // far right.
                for zone in Self.zones {
                    guard levelDBA > zone.startDB else { continue }
                    let zoneEnd = min(levelDBA, zone.endDB)
                    let leftFrac = CGFloat((zone.startDB - minDB) / (maxDB - minDB))
                    let rightFrac = CGFloat((zoneEnd - minDB) / (maxDB - minDB))
                    let rect = CGRect(
                        x: size.width * leftFrac,
                        y: 0,
                        width: size.width * (rightFrac - leftFrac),
                        height: size.height
                    )
                    ctx.fill(Path(rect), with: .color(zone.color))
                }

                // Tick markers at the dBA zone boundaries (70 caution,
                // 85 limit). With the orange zone removed, 95 no longer
                // separates two visible regions and doesn't get its own
                // tick.
                for marker in [70.0, 85.0] {
                    let frac = CGFloat((marker - minDB) / (maxDB - minDB))
                    let tick = CGRect(x: size.width * frac, y: 0, width: 1, height: size.height)
                    ctx.fill(Path(tick), with: .color(.primary.opacity(0.30)))
                }
            }
            .frame(height: 14)
            .clipShape(Capsule())
            .animation(.easeOut(duration: 0.15), value: levelDBA)

            HStack {
                Text("\(Int(minDB))")
                Spacer()
                Text("70")
                Spacer()
                Text("85")
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
        case ..<85:  return "Caution"
        default:     return "Loud"
        }
    }

    private var zoneSymbol: String {
        switch levelDBA {
        case ..<70:  return "checkmark.shield.fill"
        case ..<85:  return "exclamationmark.triangle.fill"
        default:     return "exclamationmark.octagon.fill"
        }
    }

    private var zoneColor: Color {
        switch levelDBA {
        case ..<70:  return .green
        case ..<85:  return .yellow
        default:     return .red
        }
    }

    /// Per-zone definitions used by the per-segment fill. Three zones —
    /// safe (green) below 70 dBA, caution (yellow) up to the NIOSH 85 dBA
    /// limit, danger (red) at or above the limit. Aligns red with the
    /// profile's safety ceiling rather than gating it behind an
    /// intermediate orange step.
    private struct Zone {
        let label: String
        let startDB: Double
        let endDB: Double
        let color: Color
    }
    private static let zones: [Zone] = [
        Zone(label: "safe",    startDB: 30,  endDB: 70,  color: .green),
        Zone(label: "caution", startDB: 70,  endDB: 85,  color: .yellow),
        Zone(label: "loud",    startDB: 85,  endDB: 110, color: .red),
    ]
}
