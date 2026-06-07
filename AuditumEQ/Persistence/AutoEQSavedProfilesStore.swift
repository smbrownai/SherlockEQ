import Foundation
import Combine
import OSLog

/// Ordered list of AutoEQ profiles the user has imported from the
/// remote catalog. This is the spec's "Saved Profiles List" — a
/// distinct surface from `HearingProfile` (which is the full per-user
/// audiogram + EQ chain). Each entry here is just a pointer (by AutoEQ
/// catalog `path`) into the on-disk profile cache that
/// `AutoEQRemoteService` manages.
///
/// The hearing-profile editor's "Apply" action copies the resolved
/// bands / preamp into the active `HearingProfile.autoEQ{Name,Bands,
/// PreampDB}` fields — same plumbing the existing file-picker import
/// uses — so downstream code (audio engine, conflict detection) keeps
/// reading one path.
@MainActor
final class AutoEQSavedProfilesStore: ObservableObject {

    /// One row in the saved list. The `path` is the AutoEQ catalog
    /// identifier — same string surfaced as `AutoEQIndexEntry.path`.
    /// `importedAt` drives the "imported X ago / on MM-DD" display.
    struct SavedEntry: Codable, Hashable, Identifiable {
        let path: String
        let name: String
        let source: String
        let type: String
        let importedAt: Date

        var id: String { path }
    }

    @Published private(set) var entries: [SavedEntry] {
        didSet { persist() }
    }

    private let storageKey = "sherlockeq.autoEQSavedProfiles"
    private let log = Logger(subsystem: "com.shawnbrown.SherlockEQ", category: "AutoEQSavedProfilesStore")

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder.savedProfiles.decode([SavedEntry].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = []
        }
    }

    // MARK: - List mutation

    /// True when a profile with the matching path is already saved.
    /// `AutoEQSearchView` uses this to mark already-imported rows.
    func contains(path: String) -> Bool {
        entries.contains(where: { $0.path == path })
    }

    /// Insert a newly-imported profile at the top of the list (most
    /// recent first). No-op if the same path is already present.
    func add(_ entry: SavedEntry) {
        guard !contains(path: entry.path) else { return }
        entries.insert(entry, at: 0)
        log.info("Saved AutoEQ profile: \(entry.name, privacy: .public) (\(entry.path, privacy: .public))")
    }

    /// Remove a saved entry by its path and tell the remote service
    /// to drop the on-disk cache too.
    func remove(path: String, service: AutoEQRemoteService) {
        guard let entry = entries.first(where: { $0.path == path }) else { return }
        entries.removeAll(where: { $0.path == path })
        let indexEntry = AutoEQIndexEntry(
            name: entry.name,
            path: entry.path,
            source: entry.source,
            type: entry.type
        )
        service.deleteCachedProfile(for: indexEntry)
        log.info("Removed saved AutoEQ profile: \(entry.path, privacy: .public)")
    }

    /// Look up a saved entry by path. Returns nil when the entry has
    /// been deleted or was never saved.
    func entry(for path: String) -> SavedEntry? {
        entries.first(where: { $0.path == path })
    }

    // MARK: - Apply to a hearing profile

    /// Push the cached profile's bands + preamp into the given
    /// hearing profile's AutoEQ fields and save through the profile
    /// store. Returns true on success, false when the cache is empty
    /// (caller should trigger a re-fetch through `AutoEQRemoteService`).
    func apply(
        path: String,
        to profile: HearingProfile,
        service: AutoEQRemoteService,
        profileStore: ProfileStore
    ) -> Bool {
        guard let entry = entry(for: path) else { return false }
        let indexEntry = AutoEQIndexEntry(
            name: entry.name,
            path: entry.path,
            source: entry.source,
            type: entry.type
        )
        guard let cached = service.loadCachedProfile(for: indexEntry) else {
            return false
        }
        var copy = profile
        copy.autoEQName = entry.name
        copy.autoEQBands = cached.bands
        copy.autoEQPreampDB = cached.preampGain
        do {
            try profileStore.save(copy)
            return true
        } catch {
            log.error("Apply failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Identifier the active hearing profile's AutoEQ section is
    /// currently sourced from, if any — by name match. The hearing
    /// profile stores AutoEQ data inline (it might have been imported
    /// before the remote catalog existed), so we identify "this saved
    /// entry is the one currently applied" through the user-facing
    /// name. Returns nil when the profile's AutoEQ section is empty
    /// or doesn't match any saved entry.
    func appliedPath(in profile: HearingProfile?) -> String? {
        guard let profile, let name = profile.autoEQName else { return nil }
        return entries.first(where: { $0.name == name })?.path
    }

    // MARK: - Storage

    private func persist() {
        do {
            let data = try JSONEncoder.savedProfiles.encode(entries)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            log.error("Failed to persist saved profiles list: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private extension JSONEncoder {
    static var savedProfiles: JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }
}

private extension JSONDecoder {
    static var savedProfiles: JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }
}
