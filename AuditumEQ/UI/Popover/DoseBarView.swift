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

    var body: some View {
        HStack(spacing: 8) {
            Text("Today's Dose")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(tint)
                        .frame(width: geo.size.width * clamped)
                }
            }
            .frame(height: 8)

            Text("\(Int(clamped * 100))%")
                .font(.caption.monospaced())
                .frame(width: 38, alignment: .trailing)

            Text(remainingLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 64, alignment: .trailing)
        }
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
