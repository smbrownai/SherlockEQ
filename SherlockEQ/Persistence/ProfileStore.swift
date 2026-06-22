import Foundation
import Combine
import OSLog

/// JSON-backed persistence for `HearingProfile`. One file per profile, named
/// by UUID, under `~/Library/Application Support/SherlockEQ/profiles/`.
///
/// API is intentionally narrow: `loadAll()`, `save(_:)`, `delete(_:)`,
/// `reconcileFactoryPresets()`. The store maintains a published `profiles` array
/// so SwiftUI can observe changes; writes go through `save(_:)` rather than
/// direct mutation of the array.
@MainActor
final class ProfileStore: ObservableObject {

    @Published private(set) var profiles: [HearingProfile] = []
    @Published private(set) var lastError: String?

    /// Current on-disk location. Set at init (from UserDefaults override,
    /// or the default Application Support path) and mutated by
    /// `relocate(to:moveExisting:)`. Published so Settings can show
    /// the live path and react when it changes.
    @Published private(set) var directory: URL

    /// Set by views via the SwiftUI environment so save/delete can register
    /// undo. nil while no main window is up.
    var undoManager: UndoManager?

    private let log = Logger(subsystem: "com.shawnbrown.SherlockEQ", category: "ProfileStore")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private static let directoryOverrideKey = "sherlockeq.profilesDirectory"

    /// Per-profile timestamp of the most recent save. Saves of the same
    /// profile within `coalesceWindow` are treated as one undo step, so a
    /// slider drag that fires save() dozens of times reverts as one Cmd-Z.
    private var lastBurstSaveAt: [UUID: Date] = [:]
    private let coalesceWindow: TimeInterval = 0.5

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.bootDirectory()
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
        do {
            let urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            var loaded: [HearingProfile] = []
            var skipped: [String] = []
            for url in urls where url.pathExtension == "json" {
                do {
                    let data = try Data(contentsOf: url)
                    let profile = try decoder.decode(HearingProfile.self, from: data)
                    loaded.append(profile)
                } catch {
                    log.error("Skipping \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    skipped.append(url.lastPathComponent)
                }
            }
            loaded.sort { $0.createdAt < $1.createdAt }
            profiles = loaded
            // Surface skipped files instead of clearing the error. A profile
            // that fails to decode otherwise vanishes from the list with the
            // only trace in OSLog — clearing `lastError` here hid it entirely.
            if skipped.isEmpty {
                lastError = nil
            } else {
                let names = skipped.sorted().joined(separator: ", ")
                lastError = skipped.count == 1
                    ? "Couldn't load 1 profile (\(names)) — it was skipped."
                    : "Couldn't load \(skipped.count) profiles (\(names)) — they were skipped."
            }
            return loaded
        } catch {
            // Empty result but surface the reason so DebugView (and any
            // future user-facing surface) can explain what happened —
            // most commonly the user deleted ~/Library/Application
            // Support/SherlockEQ/profiles out from under us, or the disk
            // is on an ejected volume.
            log.error("Could not enumerate profiles directory: \(error.localizedDescription, privacy: .public)")
            lastError = "Load failed: \(error.localizedDescription)"
            profiles = []
            return []
        }
    }

    /// Write `profile` to its `<uuid>.json` file (atomic via temp + rename).
    /// Bumps `modifiedAt` to now. Registers an undo entry against the
    /// current `undoManager` unless we're inside a coalescing burst (rapid
    /// repeated saves of the same profile, e.g. slider drags).
    ///
    /// On failure `lastError` is set and the error is re-thrown — callers
    /// using `try?` get the silent ignore they asked for, but the value
    /// shows up in DebugView's Profiles section.
    func save(_ profile: HearingProfile, actionName: String? = nil) throws {
        try tracking("Save") {
            ensureDirectory()
            let now = Date()
            let previousOnDisk = profiles.first { $0.id == profile.id }
            let inBurst: Bool = {
                guard let last = lastBurstSaveAt[profile.id] else { return false }
                return now.timeIntervalSince(last) < coalesceWindow
            }()

            var p = profile
            p.modifiedAt = now
            let data = try encoder.encode(p)
            let url = directory.appendingPathComponent("\(p.id.uuidString).json")
            try data.write(to: url, options: .atomic)
            if let idx = profiles.firstIndex(where: { $0.id == p.id }) {
                profiles[idx] = p
            } else {
                profiles.append(p)
                profiles.sort { $0.createdAt < $1.createdAt }
            }

            if let undoManager, !inBurst {
                // Caller-supplied name (e.g. "Adjust 1 kHz" from a band drag)
                // wins; otherwise fall back to the generic create/edit label.
                let resolvedName = actionName ?? (previousOnDisk == nil ? "Create \(p.name)" : "Edit \(p.name)")
                if let snapshot = previousOnDisk {
                    undoManager.registerUndo(withTarget: self) { store in
                        try? store.save(snapshot)
                    }
                } else {
                    // First time this profile hit disk → undo = delete.
                    undoManager.registerUndo(withTarget: self) { store in
                        try? store.delete(p)
                    }
                }
                undoManager.setActionName(resolvedName)
            }
            lastBurstSaveAt[profile.id] = now

            log.info("Saved profile \(p.name, privacy: .public) (\(p.id.uuidString, privacy: .public))")
        }
    }

    /// Encode `profile` to a user-chosen location. Independent of the
    /// internal profiles directory — used for sharing profiles between
    /// machines or with other users.
    func exportProfile(_ profile: HearingProfile, to url: URL) throws {
        try tracking("Export") {
            let data = try encoder.encode(profile)
            try data.write(to: url, options: .atomic)
            log.info("Exported \(profile.name, privacy: .public) to \(url.lastPathComponent, privacy: .public)")
        }
    }

    /// Read a profile JSON from `url`, dedupe its ID and name against the
    /// current store, force `isBuiltIn = false` (the imported copy is the
    /// user's own), and persist it. Returns the saved profile so callers
    /// can switch selection or activate it.
    @discardableResult
    func importProfile(from url: URL) throws -> HearingProfile {
        try tracking("Import") {
            let data = try Data(contentsOf: url)
            var imported = try decoder.decode(HearingProfile.self, from: data)
            if profiles.contains(where: { $0.id == imported.id }) {
                imported.id = UUID()
            }
            imported.name = uniqueName(base: imported.name)
            imported.isBuiltIn = false
            try save(imported)
            log.info("Imported \(imported.name, privacy: .public) from \(url.lastPathComponent, privacy: .public)")
            return imported
        }
    }

    private func uniqueName(base: String) -> String {
        let existing = Set(profiles.map(\.name))
        if !existing.contains(base) { return base }
        var i = 2
        while existing.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    /// Remove the on-disk file and drop the profile from the in-memory
    /// array. Registers an undo that re-saves the deleted snapshot.
    func delete(_ profile: HearingProfile) throws {
        try tracking("Delete") {
            let url = directory.appendingPathComponent("\(profile.id.uuidString).json")
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            profiles.removeAll { $0.id == profile.id }
            lastBurstSaveAt[profile.id] = nil

            if let undoManager {
                undoManager.registerUndo(withTarget: self) { store in
                    try? store.save(profile)
                }
                undoManager.setActionName("Delete \(profile.name)")
            }

            log.info("Deleted profile \(profile.name, privacy: .public)")
        }
    }

    // MARK: - Factory listening presets

    /// Bumped whenever the shipped factory-preset set changes. A launch that
    /// sees a lower stored version runs the one-time reconcile below.
    private static let factoryPresetsVersion = 1
    private static let factoryPresetsVersionKey = "sherlockeq.factoryPresetsVersion"

    private var storedFactoryVersion: Int {
        get { UserDefaults.standard.integer(forKey: Self.factoryPresetsVersionKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.factoryPresetsVersionKey) }
    }

    private var factoryIDs: Set<UUID> { Set(HearingProfile.factoryProfiles.map(\.id)) }

    /// One-time-per-version migration. Removes legacy built-ins that aren't
    /// one of the current factory presets (e.g. the old "Default" / "Voice
    /// Clarity" with random ids), then installs any of the four canonical
    /// presets that are missing by id. Gated on `factoryPresetsVersion` so a
    /// preset the user deliberately deleted is NOT silently re-added on every
    /// launch — only on a genuine version bump. Existing-by-id presets are
    /// left untouched so in-place edits survive.
    func reconcileFactoryPresets() {
        guard storedFactoryVersion < Self.factoryPresetsVersion else { return }
        do {
            let canonicalIDs = factoryIDs
            // Drop legacy built-ins (random-id Default / Voice Clarity, or
            // factory presets retired in a past version). User profiles
            // (isBuiltIn == false) are never touched.
            for legacy in profiles where legacy.isBuiltIn && !canonicalIDs.contains(legacy.id) {
                try delete(legacy)
            }
            // Install any canonical preset that isn't present by id.
            for preset in HearingProfile.factoryProfiles where !profiles.contains(where: { $0.id == preset.id }) {
                try save(preset)
            }
            storedFactoryVersion = Self.factoryPresetsVersion
            log.info("Reconciled factory presets to version \(Self.factoryPresetsVersion)")
        } catch {
            lastError = "Could not install factory presets: \(error.localizedDescription)"
            log.error("Factory reconcile failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// "Restore Factory Presets" — force every canonical preset back to its
    /// shipped values (recreating any the user deleted, overwriting any they
    /// edited), and drop retired legacy built-ins. User profiles untouched.
    func restoreFactoryPresets() {
        do {
            let canonicalIDs = factoryIDs
            for legacy in profiles where legacy.isBuiltIn && !canonicalIDs.contains(legacy.id) {
                try delete(legacy)
            }
            for preset in HearingProfile.factoryProfiles {
                try save(preset)
            }
            storedFactoryVersion = Self.factoryPresetsVersion
            log.info("Restored all factory presets")
        } catch {
            lastError = "Could not restore factory presets: \(error.localizedDescription)"
            log.error("Factory restore failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// "Reset to Factory Default" for a single profile. Overwrites the profile
    /// at `id` with its canonical factory values. No-op for user profiles
    /// (ids that aren't one of the four factory presets).
    func resetProfileToFactory(_ id: UUID) {
        guard let canonical = HearingProfile.factoryCanonical(forID: id) else { return }
        do {
            try save(canonical)
            log.info("Reset \(canonical.name, privacy: .public) to factory default")
        } catch {
            lastError = "Could not reset profile: \(error.localizedDescription)"
            log.error("Factory reset failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// True when `profile` is a factory preset whose current values differ
    /// from its shipped canonical version — drives the "Reset to Factory
    /// Default" button's enabled state.
    func differsFromFactory(_ profile: HearingProfile) -> Bool {
        guard let canonical = HearingProfile.factoryCanonical(forID: profile.id) else { return false }
        return !profile.leftEar.bands.audiblyEquivalent(to: canonical.leftEar.bands)
            || !profile.rightEar.bands.audiblyEquivalent(to: canonical.rightEar.bands)
            || abs(profile.globalTrimDB - canonical.globalTrimDB) > 0.001
            || profile.name != canonical.name
            || profile.balance != canonical.balance
    }

    // MARK: - Helpers

    var storageDirectory: URL { directory }

    private func ensureDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                // Subsequent save / loadAll calls will fail with less-
                // actionable I/O errors; capture the underlying cause
                // here so DebugView (and any future user-facing
                // surface) can explain it. Common causes: the path is
                // a regular file rather than a directory, the volume
                // is read-only, or the user pointed `relocate` at a
                // path they no longer have write access to.
                log.error("Could not create profiles dir: \(error.localizedDescription, privacy: .public)")
                lastError = "Could not create profiles directory: \(error.localizedDescription)"
            }
        }
    }

    static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("SherlockEQ", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
    }

    /// Directory the store should use at boot. Honors a UserDefaults override
    /// (set via `relocate(to:moveExisting:)`) so a user who points the store
    /// at iCloud Drive / Dropbox / an external disk keeps that across
    /// launches. Falls back to the default Application Support path.
    static func bootDirectory() -> URL {
        if let path = UserDefaults.standard.string(forKey: directoryOverrideKey),
           !path.isEmpty {
            // Reject an override that points inside the per-user temporary
            // directory. A user never relocates profiles there; the only way
            // it happens is test pollution — ProfileStoreTests runs hosted in
            // the app bundle, so `relocate(to:)` writes its temp path into the
            // shared production defaults domain. macOS purges /var/folders/.../T
            // on reboot, so honoring the path would silently surface an empty
            // profile list after a restart while the real data sits untouched
            // in the default folder. Self-heal by clearing the stale key.
            let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
            if URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(tempRoot) {
                UserDefaults.standard.removeObject(forKey: directoryOverrideKey)
                return defaultDirectory()
            }
            return URL(fileURLWithPath: path)
        }
        return defaultDirectory()
    }

    // MARK: - Relocation

    enum RelocationError: Error, LocalizedError {
        case sourceIsDestination
        case moveFailed(String)

        var errorDescription: String? {
            switch self {
            case .sourceIsDestination: return "The new folder is the same as the current folder."
            case .moveFailed(let s): return "Move failed: \(s)"
            }
        }
    }

    /// Switch the persistence directory at runtime. If `moveExisting` is true,
    /// every `<uuid>.json` currently in the old folder is moved into the new
    /// one (overwriting on collision — the in-memory store is the truth).
    /// Either way, the override is persisted and `loadAll()` is called so
    /// the in-memory profile list reflects whatever's in the new folder.
    func relocate(to newDirectory: URL, moveExisting: Bool) throws {
        try tracking("Relocate") {
            let oldDirectory = directory
            if newDirectory.standardizedFileURL == oldDirectory.standardizedFileURL {
                throw RelocationError.sourceIsDestination
            }

            let fm = FileManager.default
            if !fm.fileExists(atPath: newDirectory.path) {
                try fm.createDirectory(at: newDirectory, withIntermediateDirectories: true)
            }

            if moveExisting, fm.fileExists(atPath: oldDirectory.path) {
                let oldURLs = (try? fm.contentsOfDirectory(at: oldDirectory, includingPropertiesForKeys: nil)) ?? []
                let sources = oldURLs.filter { $0.pathExtension == "json" }

                // Two-phase commit so a mid-flight failure can't split the
                // user's data across two directories:
                //
                //   Phase 1 — copy every profile JSON from old → new.
                //   If any copy throws, roll back the partial new-dir
                //   contents and bail; the old directory is untouched
                //   so the user's data is preserved exactly as it was.
                //
                //   Phase 2 — delete the originals from the old dir.
                //   A failure here leaves duplicate files in both
                //   directories (no data loss), so we log the offending
                //   names rather than throw — the new dir is canonical
                //   and the relocation is functionally complete.
                var copiedDestinations: [URL] = []
                do {
                    for src in sources {
                        let dst = newDirectory.appendingPathComponent(src.lastPathComponent)
                        if fm.fileExists(atPath: dst.path) {
                            try fm.removeItem(at: dst)
                        }
                        try fm.copyItem(at: src, to: dst)
                        copiedDestinations.append(dst)
                    }
                } catch {
                    for dst in copiedDestinations {
                        try? fm.removeItem(at: dst)
                    }
                    throw RelocationError.moveFailed(error.localizedDescription)
                }

                var phase2Failures: [String] = []
                for src in sources {
                    do {
                        try fm.removeItem(at: src)
                    } catch {
                        phase2Failures.append(src.lastPathComponent)
                    }
                }
                if !phase2Failures.isEmpty {
                    log.error(
                        "Relocate phase-2 left \(phase2Failures.count, privacy: .public) file(s) in old dir: \(phase2Failures.joined(separator: ", "), privacy: .public)"
                    )
                }
            }

            directory = newDirectory
            if newDirectory.standardizedFileURL == Self.defaultDirectory().standardizedFileURL {
                UserDefaults.standard.removeObject(forKey: Self.directoryOverrideKey)
            } else {
                UserDefaults.standard.set(newDirectory.path, forKey: Self.directoryOverrideKey)
            }
            loadAll()
        }
    }

    // MARK: - Error tracking

    /// Wrap every throwing public operation so `lastError` reflects the
    /// outcome of the most recent attempt — set on failure, cleared on
    /// success. Callers using `try?` still get the silent ignore they
    /// asked for; the published value lets DebugView surface what went
    /// wrong even when the call site swallowed the error.
    private func tracking<T>(_ operation: String, _ work: () throws -> T) throws -> T {
        do {
            let result = try work()
            lastError = nil
            return result
        } catch {
            lastError = "\(operation) failed: \(error.localizedDescription)"
            throw error
        }
    }
}
