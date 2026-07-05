import Foundation
import Combine
import OSLog

/// Persists a rolling window of daily tinnitus-annoyance check-ins to a single
/// JSON file in Application Support.
///
/// Mirrors `DoseHistoryStore`'s shape (injectable file URL, atomic writes,
/// `lastError` surface) so it stays testable against a temp file and never
/// touches the user's real history during unit tests. Unlike dose peaks, a
/// check-in is the user's stated rating, so a same-day re-entry *replaces* the
/// value rather than taking the maximum.
@MainActor
final class TinnitusCheckInStore: ObservableObject {

    /// Oldest first, newest last. Capped at `retentionDays`.
    @Published private(set) var records: [TinnitusCheckIn] = []
    /// Surfaces load/save failures (consumed by DebugView, like ProfileStore).
    @Published private(set) var lastError: String?

    /// A year of daily check-ins is tiny on disk; retain generously so a
    /// future longer trend view has data without a format change.
    static let retentionDays = 365

    private let fileURL: URL
    private let log = Logger(subsystem: "com.shawnbrown.SherlockEQ", category: "TinnitusCheckIn")

    init(fileURL: URL = TinnitusCheckInStore.defaultFileURL()) {
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
            .appendingPathComponent("tinnitus-checkins.json", isDirectory: false)
    }

    /// Load the persisted history. Missing file is normal (no check-ins yet)
    /// and leaves `records` empty without an error.
    func loadAll() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            records = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try Self.makeDecoder().decode([TinnitusCheckIn].self, from: data)
            records = decoded.sorted { $0.dayStart < $1.dayStart }
            lastError = nil
        } catch {
            lastError = "Couldn't load tinnitus check-ins: \(error.localizedDescription)"
            log.error("loadAll failed: \(error.localizedDescription, privacy: .public)")
            records = []
        }
    }

    /// The rating recorded for a given day, or nil if none.
    func rating(on day: Date = Date()) -> Int? {
        let start = Calendar.current.startOfDay(for: day)
        return records.first { Calendar.current.isDate($0.dayStart, inSameDayAs: start) }?.annoyance
    }

    /// Record (or replace) a day's annoyance rating. Clamped to 0…10, pruned to
    /// `retentionDays`, persisted atomically.
    func record(annoyance: Int, on day: Date = Date()) {
        let start = Calendar.current.startOfDay(for: day)
        let clamped = min(10, max(0, annoyance))

        var next = records.filter { !Calendar.current.isDate($0.dayStart, inSameDayAs: start) }
        next.append(TinnitusCheckIn(dayStart: start, annoyance: clamped))
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
            // Exclude from Time Machine and other backup tools — this is a log
            // of the user's health-adjacent self-reports and shouldn't
            // accumulate in historical backups with no in-app way to purge it.
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
            lastError = "Couldn't save tinnitus check-ins: \(error.localizedDescription)"
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
