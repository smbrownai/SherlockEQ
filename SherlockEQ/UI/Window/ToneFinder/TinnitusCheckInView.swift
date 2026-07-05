import SwiftUI
import Charts

/// A lightweight daily "how bothersome was your tinnitus today" check-in with a
/// short trend. Explicitly non-clinical: 0–10, no validated scoring, framed
/// around annoyance/distress (which is what habituation and sound therapy
/// target) rather than loudness. Helps the user see whether things trend
/// better over time instead of chasing the ringing minute to minute.
struct TinnitusCheckInView: View {
    @ObservedObject var store: TinnitusCheckInStore

    /// Draft rating for today's slider (0…10). Seeded from any existing entry
    /// for today, otherwise a neutral mid-point.
    @State private var draft: Double = 5
    @State private var savedToday = false

    private static let windowDays = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(spacing: 12) {
                Text("Not at all").font(.caption).foregroundStyle(.secondary)
                Slider(value: $draft, in: 0...10, step: 1) { editing in
                    if editing { savedToday = false }
                }
                Text("Extremely").font(.caption).foregroundStyle(.secondary)
                Text("\(Int(draft))")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .frame(width: 32, alignment: .trailing)
            }

            HStack(spacing: 12) {
                Button {
                    store.record(annoyance: Int(draft))
                    savedToday = true
                } label: {
                    Label(store.rating() == nil ? "Save today's rating" : "Update today's rating",
                          systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if savedToday {
                    Label("Saved", systemImage: "checkmark")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
                Spacer()
            }

            if hasTrend {
                trendChart
            }

            Text("Not a clinical score. This tracks how much the ringing bothered you — separate from how loud it seems — so you can see a trend rather than a single day.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.05))
        )
        .onAppear {
            if let today = store.rating() {
                draft = Double(today)
                savedToday = true
            }
        }
    }

    private var header: some View {
        HStack {
            Label("Tinnitus check-in", systemImage: "calendar.badge.clock")
                .font(.title3.weight(.semibold))
            Spacer()
        }
    }

    // MARK: - Trend

    private struct DayPoint: Identifiable {
        let day: Date
        let label: String
        let annoyance: Int
        var id: Date { day }
    }

    private var points: [DayPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let fmt = DateFormatter()
        fmt.locale = .current
        fmt.setLocalizedDateFormatFromTemplate("MMMd")

        return (0..<Self.windowDays).reversed().compactMap { offset -> DayPoint? in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            guard let rating = store.records
                .first(where: { cal.isDate($0.dayStart, inSameDayAs: day) })?
                .annoyance else { return nil }
            return DayPoint(day: day, label: fmt.string(from: day), annoyance: rating)
        }
    }

    private var hasTrend: Bool { points.count >= 2 }

    private var trendChart: some View {
        Chart(points) { point in
            LineMark(
                x: .value("Day", point.day),
                y: .value("Annoyance", point.annoyance)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(.tint)
            PointMark(
                x: .value("Day", point.day),
                y: .value("Annoyance", point.annoyance)
            )
            .foregroundStyle(.tint)
        }
        .chartYScale(domain: 0...10)
        .chartYAxis {
            AxisMarks(values: [0, 5, 10]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text("\(v)") }
                }
            }
        }
        .frame(height: 120)
        .accessibilityLabel("Tinnitus annoyance trend, last \(Self.windowDays) days")
        .accessibilityValue(points.map { "\($0.label): \($0.annoyance)" }.joined(separator: ", "))
    }
}
