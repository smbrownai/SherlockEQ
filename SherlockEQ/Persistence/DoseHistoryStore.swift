import Foundation
import Combine
import OSLog

/// Persists a rolling window of daily listening-dose peaks to a single JSON
/// file in Application Support.
///
/// `SafeListeningTracker` finalizes a day — at the midnight rollover while the
/// app runs, or at launch when it detects the app was closed across midnight —
/// and hands the day's peak here (wired through `AudioState`). The Safe
/// Listening screen's 7-day chart reads `records`.
///
/// Mirrors `ProfileStore`'s shape (injectable file URL, atomic writes,
/// `lastError` surface) so it stays testable against a temp file and never
/// touches the user's real history during unit tests.
@MainActor
final class DoseHistoryStore: ObservableObject {

    /// Oldest first, newest last. Capped at `retentionDays`.
    @Published private(set) var records: [DailyDoseRecord] = []
    /// Surfaces load/save failures (consumed by DebugView, like ProfileStore).
    @Published private(set) var lastError: String?

    /// How many days we keep on disk. The chart shows 7; we retain more so a
    /// future longer view (or an export) has data without a format change.
    static let retentionDays = 90

    private let fileURL: URL
    private let log = Logger(subsystem: "com.shawnbrown.SherlockEQ", category: "DoseHistory")

    init(fileURL: URL = DoseHistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    nonisolated static func defaultFileURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("SherlockEQ", isDirectory: true)
            .appendingPathComponent("dose-history.json", isDirectory: false)
    }

    /// Load the persisted history. Missing file is normal (no listening yet)
    /// and leaves `records` empty without an error.
    func loadAll() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            records = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try Self.makeDecoder().decode([DailyDoseRecord].self, from: data)
            records = decoded.sorted { $0.dayStart < $1.dayStart }
            lastError = nil
        } catch {
            lastError = "Couldn't load dose history: \(error.localizedDescription)"
            log.error("loadAll failed: \(error.localizedDescription, privacy: .public)")
            records = []
        }
    }

    /// Record one day's peak. Normalised to the day's start-of-day; a record
    /// for an existing day keeps the higher of the two peaks (so a same-day
    /// re-finalize never lowers it). Days with no exposure (peak 0) aren't
    /// stored — an absent bar means "no listening", not "zero dose". Prunes to
    /// `retentionDays` and persists atomically.
    func record(dayStart: Date, peakDose: Double) {
        let day = Calendar.current.startOfDay(for: dayStart)
        let clamped = min(1, max(0, peakDose))
        guard clamped > 0 else { return }

        let existingPeak = records
            .first { Calendar.current.isDate($0.dayStart, inSameDayAs: day) }?
            .peakDose ?? 0
        let merged = max(existingPeak, clamped)

        var next = records.filter { !Calendar.current.isDate($0.dayStart, inSameDayAs: day) }
        next.append(DailyDoseRecord(dayStart: day, peakDose: merged))
        next.sort { $0.dayStart < $1.dayStart }
        if next.count > Self.retentionDays {
            next.removeFirst(next.count - Self.retentionDays)
        }
        records = next
        save()
    }

    /// Drop records from the most recent `days` calendar days (inclusive of
    /// today). Debug/testing affordance for re-exercising the empty state.
    func removeRecent(days: Int) {
        guard days > 0 else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let cutoff = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return }
        let filtered = records.filter { $0.dayStart < cutoff }
        guard filtered.count != records.count else { return }
        records = filtered
        save()
    }

    private func save() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Exclude from Time Machine and other backup tools — dose
            // history is a log of the user's daily noise exposure and
            // shouldn't accumulate in historical backups with no way to
            // purge it from within the app. Best-effort and idempotent.
            var backupTarget = directory
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? backupTarget.setResourceValues(resourceValues)

            let data = try Self.makeEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
            // Owner-only, independent of the containing directory's mode.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            lastError = nil
        } catch {
            lastError = "Couldn't save dose history: \(error.localizedDescription)"
            log.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
