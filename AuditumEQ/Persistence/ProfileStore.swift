import Foundation
import Combine
import OSLog

/// JSON-backed persistence for `HearingProfile`. One file per profile, named
/// by UUID, under `~/Library/Application Support/AuditumEQ/profiles/`.
///
/// API is intentionally narrow: `loadAll()`, `save(_:)`, `delete(_:)`,
/// `seedDefaultsIfEmpty()`. The store maintains a published `profiles` array
/// so SwiftUI can observe changes; writes go through `save(_:)` rather than
/// direct mutation of the array.
@MainActor
final class ProfileStore: ObservableObject {

    @Published private(set) var profiles: [HearingProfile] = []
    @Published private(set) var lastError: String?

    private let log = Logger(subsystem: "com.shawnbrown.AuditumEQ", category: "ProfileStore")
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        self.encoder = {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            e.dateEncodingStrategy = .iso8601
            return e
        }()
        self.decoder = {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return d
        }()
    }

    // MARK: - Public

    /// Read every `<uuid>.json` file in the profiles directory. Unparseable
    /// files are logged and skipped rather than aborting the load.
    @discardableResult
    func loadAll() -> [HearingProfile] {
        ensureDirectory()
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            log.error("Could not enumerate profiles directory")
            profiles = []
            return []
        }
        var loaded: [HearingProfile] = []
        for url in urls where url.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: url)
                let profile = try decoder.decode(HearingProfile.self, from: data)
                loaded.append(profile)
            } catch {
                log.error("Skipping \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        loaded.sort { $0.createdAt < $1.createdAt }
        profiles = loaded
        lastError = nil
        return loaded
    }

    /// Write `profile` to its `<uuid>.json` file (atomic via temp + rename).
    /// Bumps `modifiedAt` to now.
    func save(_ profile: HearingProfile) throws {
        ensureDirectory()
        var p = profile
        p.modifiedAt = Date()
        let data = try encoder.encode(p)
        let url = directory.appendingPathComponent("\(p.id.uuidString).json")
        try data.write(to: url, options: .atomic)
        if let idx = profiles.firstIndex(where: { $0.id == p.id }) {
            profiles[idx] = p
        } else {
            profiles.append(p)
            profiles.sort { $0.createdAt < $1.createdAt }
        }
        log.info("Saved profile \(p.name, privacy: .public) (\(p.id.uuidString, privacy: .public))")
    }

    /// Remove the on-disk file and drop the profile from the in-memory array.
    func delete(_ profile: HearingProfile) throws {
        let url = directory.appendingPathComponent("\(profile.id.uuidString).json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        profiles.removeAll { $0.id == profile.id }
        log.info("Deleted profile \(profile.name, privacy: .public)")
    }

    /// On first launch, seed a "Default" profile and the Voice Clarity preset
    /// so the user always has something selected when they open the app.
    func seedDefaultsIfEmpty() {
        guard profiles.isEmpty else { return }
        do {
            try save(.makeDefault())
            try save(.makeVoiceClarityPreset())
            log.info("Seeded initial profiles")
        } catch {
            lastError = "Could not seed defaults: \(error.localizedDescription)"
            log.error("Seed failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    var storageDirectory: URL { directory }

    private func ensureDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                log.error("Could not create profiles dir: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("AuditumEQ", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
    }
}
