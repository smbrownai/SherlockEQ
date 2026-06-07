import SwiftUI

/// Compact horizontal dose bar for the popover. Placeholder shape; the real
/// `SafeListeningTracker` lands in Session 10–11. For now the bar reflects
/// `state.sessionDosePercent` which stays at 0 until that wiring exists.
struct DoseBarView: View {
    let percent: Double           // 0…1
    let remainingMinutes: Double? // nil → no estimate yet

    private var clamped: Double { max(0, min(1, percent)) }

    private var tint: Color {
        switch clamped {
        case ..<0.6:  return .green
        case ..<0.85: return .orange
        default:      return .red
        }
    }

    /// Redundant non-color encoding paired with `tint`. Colorblind
    /// users see the icon shape distinguish safe / approaching / at-
    /// limit without relying on green vs orange vs red. Same pattern
    /// LevelMeterView uses for its zone labels.
    private var zoneSymbol: String {
        switch clamped {
        case ..<0.6:  return "checkmark.shield.fill"
        case ..<0.85: return "exclamationmark.triangle.fill"
        default:      return "exclamationmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Today's Dose")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                // minWidth instead of width so localized strings
                // ("Heutige Dosis", "Dose du jour") can grow past 80pt
                // at large Dynamic Type without truncating.
                .frame(minWidth: 80, alignment: .leading)
                .layoutPriority(1)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(tint)
                        .frame(width: geo.size.width * clamped)
                }
            }
            .frame(height: 8)

            // Icon paired with the percent value gives colorblind
            // users the same severity signal the bar tint carries.
            HStack(spacing: 4) {
                Image(systemName: zoneSymbol)
                    .foregroundStyle(tint)
                    .font(.caption.weight(.semibold))
                Text("\(Int(clamped * 100))%")
                    .font(.caption.monospaced())
            }
            .frame(minWidth: 56, alignment: .trailing)

            Text(remainingLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 64, alignment: .trailing)
        }
        // Roll the four sibling Texts into one VO element so the
        // bar reads as "Today's listening dose: 47%, ~3h 12m
        // remaining" instead of four separate fragments in unspecified
        // order. Safety-critical surface — needs to read as one thing.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today's listening dose")
        .accessibilityValue(accessibilityValueString)
    }

    private var accessibilityValueString: String {
        let percentStr = "\(Int(clamped * 100))%"
        let zone: String = {
            switch clamped {
            case ..<0.6:  return "safe"
            case ..<0.85: return "approaching limit"
            default:      return "at or past limit"
            }
        }()
        return "\(percentStr), \(zone), \(remainingLabel)"
    }

    private var remainingLabel: String {
        guard let minutes = remainingMinutes, minutes.isFinite else { return "—" }
        if minutes >= 24 * 60 {
            return String(localized: "all day", comment: "Dose bar: remaining safe-listening time when above a day")
        }
        if minutes >= 60 {
            let h = Int(minutes) / 60
            let m = Int(minutes) % 60
            return String(
                localized: "~\(h)h \(m)m",
                comment: "Dose bar: hours + minutes remaining"
            )
        }
        return String(
            localized: "~\(Int(minutes))m",
            comment: "Dose bar: minutes remaining"
        )
    }
}
