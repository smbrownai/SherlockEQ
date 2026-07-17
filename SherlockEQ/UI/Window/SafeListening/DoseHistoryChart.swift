import SwiftUI
import Charts

/// 7-day listening-dose history bar chart for the Safe Listening screen.
///
/// Each bar is a day's peak dose (0–100 %); colours match the live dose card's
/// green / amber / red bands (80 % / 100 % thresholds, drawn as dashed rules).
/// Past days come from `DoseHistoryStore`; "today" reads the tracker's live
/// running peak, since no record is written for today until the midnight
/// rollover. Days with no listening are simply absent (no bar).
struct DoseHistoryChart: View {
    @ObservedObject var history: DoseHistoryStore
    @ObservedObject var tracker: SafeListeningTracker

    /// Number of days shown, ending today.
    private static let windowDays = 7

    private struct DayBar: Identifiable {
        let dayStart: Date
        let label: String
        let isToday: Bool
        /// Peak dose 0…1, or nil when there was no listening that day.
        let dose: Double?
        var id: Date { dayStart }
    }

    private var days: [DayBar] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = DateFormatter()
        weekday.locale = .current
        weekday.setLocalizedDateFormatFromTemplate("EEE")

        return (0..<Self.windowDays).reversed().compactMap { offset -> DayBar? in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let isToday = offset == 0
            let stored = history.records
                .first { cal.isDate($0.dayStart, inSameDayAs: day) }?
                .peakDose
            // Today's live peak isn't in the store yet; fold it in (and keep the
            // higher of the two in case a record already exists for today).
            let value: Double? = isToday
                ? max(stored ?? 0, tracker.peakDoseToday)
                : stored
            let dose = (value ?? 0) > 0 ? value : nil
            return DayBar(
                dayStart: day,
                label: isToday ? "Today" : weekday.string(from: day),
                isToday: isToday,
                dose: dose
            )
        }
    }

    var body: some View {
        if days.allSatisfy({ $0.dose == nil }) {
            Text("No listening recorded yet. Days appear here once you've used SherlockEQ across a midnight rollover.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            chart
        }
    }

    private var chart: some View {
        Chart {
            ForEach(days) { day in
                if let dose = day.dose {
                    BarMark(
                        x: .value("Day", day.label),
                        y: .value("Peak dose", dose * 100)
                    )
                    .foregroundStyle(color(forDose: dose).gradient)
                    .cornerRadius(3)
                    .annotation(position: .top, spacing: 2) {
                        Text("\(Int(dose * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            RuleMark(y: .value("Warn", 80))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.orange.opacity(0.45))
            RuleMark(y: .value("Limit", 100))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.red.opacity(0.45))
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 80, 100]) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let pct = value.as(Int.self) {
                        Text("\(pct)%")
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
            }
        }
        .frame(height: 170)
        .accessibilityLabel("7-day listening exposure history")
        .accessibilityValue(accessibilitySummary)
    }

    /// Bar colour by the same bands as the live dose card.
    private func color(forDose dose: Double) -> Color {
        if dose >= 1.0 { return .red }
        if dose >= 0.8 { return .orange }
        return .green
    }

    private var accessibilitySummary: String {
        let parts = days.map { day -> String in
            guard let dose = day.dose else { return "\(day.label): no listening" }
            return "\(day.label): \(Int(dose * 100)) percent"
        }
        return parts.joined(separator: ", ")
    }
}
