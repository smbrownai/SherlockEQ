import SwiftUI

/// Today's-exposure row for the popover: a bar plus an honest qualifier.
///
/// This used to show a green "safe" shield and a percentage unconditionally —
/// so with no audio playing it read `0%` beside a green check, asserting a
/// safety conclusion from a measurement that was never taken. The state now
/// comes from `AudioState.exposureStatus`, the same read the Safe Listening
/// screen uses, and the qualifier names which of the three we're in:
///
///     Exposure [Today]   —     Waiting for audio
///     Exposure [Today]   ≈3%   Not calibrated
///     Exposure [Today]   24%   ~3h 12m
///
/// Green is reserved for a calibrated, actively-tracked estimate. Amber/red
/// still show whenever crossed — those are safety signals that matter
/// regardless of how confident the number is.
struct DoseBarView: View {
    let percent: Double           // 0…1
    let status: ExposureStatus
    let severity: SafeListeningTracker.DoseSeverity
    let remainingMinutes: Double? // nil → no estimate yet

    private var clamped: Double { max(0, min(1, percent)) }

    /// Amber/red are safety signals and always show. "Safe" only earns green
    /// once it's a calibrated, tracked estimate — an approximate one reads
    /// neutral, an unknown one never colours at all.
    private var tint: Color {
        switch severity {
        case .red:   return .red
        case .amber: return .orange
        case .safe:  return status == .tracked ? .green : .secondary
        }
    }

    /// Redundant non-colour encoding paired with `tint` so colourblind users
    /// get the same signal. No check-shield while unknown/approximate — the
    /// shape would claim the same "verified safe" the colour does.
    private var zoneSymbol: String? {
        switch severity {
        case .red:   return "exclamationmark.octagon.fill"
        case .amber: return "exclamationmark.triangle.fill"
        case .safe:  return status == .tracked ? "checkmark.shield.fill" : nil
        }
    }

    /// A dash when there's no measurement; "≈" when the level is uncalibrated
    /// and the number's magnitude isn't trustworthy.
    private var valueLabel: String {
        switch status {
        case .unknown:     return "—"
        case .approximate: return "≈\(Int(clamped * 100))%"
        case .tracked:     return "\(Int(clamped * 100))%"
        }
    }

    private var qualifier: String {
        switch status {
        case .unknown:     return "Waiting for audio"
        case .approximate: return "Not calibrated"
        case .tracked:     return remainingLabel
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text("Exposure")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                ScopeBadge(scope: .session)
            }
            .frame(width: 108, alignment: .leading)
            .layoutPriority(1)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    // Nothing to fill while unknown — an empty track reads as
                    // "no reading", which is exactly the state.
                    if status != .unknown {
                        Capsule()
                            .fill(tint)
                            .frame(width: geo.size.width * clamped)
                    }
                }
            }
            .frame(height: 8)

            HStack(spacing: 4) {
                if let zoneSymbol {
                    Image(systemName: zoneSymbol)
                        .foregroundStyle(tint)
                        .font(.caption.weight(.semibold))
                }
                Text(valueLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(status == .unknown ? .secondary : .primary)
            }
            .frame(minWidth: 56, alignment: .trailing)

            Text(qualifier)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 76, alignment: .trailing)
        }
        // Roll the row into one VO element so it reads as a single statement
        // rather than four fragments. Safety-critical surface.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today's exposure")
        .accessibilityValue(accessibilityValueString)
    }

    private var accessibilityValueString: String {
        switch status {
        case .unknown:
            return "Unknown — waiting for audio"
        case .approximate:
            return "About \(Int(clamped * 100)) percent, not calibrated"
        case .tracked:
            let zone: String = {
                switch severity {
                case .safe:  return "under your limit"
                case .amber: return "approaching limit"
                case .red:   return "at or past limit"
                }
            }()
            return "\(Int(clamped * 100)) percent, \(zone), \(remainingLabel)"
        }
    }

    private var remainingLabel: String {
        guard let minutes = remainingMinutes, minutes.isFinite else { return "—" }
        if minutes >= 24 * 60 {
            return String(localized: "all day", comment: "Exposure row: remaining safe-listening time when above a day")
        }
        if minutes >= 60 {
            let h = Int(minutes) / 60
            let m = Int(minutes) % 60
            return String(
                localized: "~\(h)h \(m)m",
                comment: "Exposure row: hours + minutes remaining"
            )
        }
        return String(
            localized: "~\(Int(minutes))m",
            comment: "Exposure row: minutes remaining"
        )
    }
}
