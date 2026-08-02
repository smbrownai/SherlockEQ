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

    /// Where the factory-presets version gate and the directory override
    /// live. Injectable because ProfileStoreTests runs hosted in the app, so
    /// `.standard` IS the production domain — a leaked test key once pointed
    /// the real app at a reboot-purged temp folder (audit TD-02).
    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private static let directoryOverrideKey = "sherlockeq.profilesDirectory"

    /// Per-profile timestamp of the most recent save. Saves of the same
    /// profile within `coalesceWindow` are treated as one undo step, so a
    /// slider drag that fires save() dozens of times reverts as one Cmd-Z.
    private var lastBurstSaveAt: [UUID: Date] = [:]
    private let coalesceWindow: TimeInterval = 0.5

    /// Latest unwritten snapshot per profile, flushed by a trailing debounce.
    /// `save(_:)` applies the change to memory and publishes immediately — the
    /// UI and the audio engine follow live — but the JSON encode + atomic
    /// write costs are paid once per burst, not per slider tick: a 60 Hz drag
    /// used to mean ~60 full-profile encodes + temp-write/rename/chmod per
    /// second on the main thread. Durability points: the debounce firing,
    /// `flushPendingWrites()` (called by relocate, loadAll, and app
    /// termination), and `delete(_:)` cancelling its profile's entry.
    private var pendingWrites: [UUID: HearingProfile] = [:]
    private var pendingFlush: DispatchWorkItem?
    private let writeDebounce: TimeInterval = 0.3

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.directory = directory ?? Self.bootDirectory(defaults: defaults)
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
        // Land any unwritten snapshots first — reading the directory with
        // writes still pending would replace newer in-memory state with
        // stale disk contents.
        flushPendingWrites()
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

    /// Apply `profile` to the in-memory store (publishing immediately, so the
    /// UI and audio engine follow live) and schedule its `<uuid>.json` write
    /// behind a trailing debounce. Bumps `modifiedAt` to now. Registers an
    /// undo entry against the current `undoManager` unless we're inside a
    /// coalescing burst (rapid repeated saves, e.g. slider drags).
    ///
    /// Disk errors surface asynchronously via `lastError` (→ the notice
    /// banner) when the deferred write runs — same visibility as before,
    /// since effectively every caller used `try?` anyway.
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
            if let idx = profiles.firstIndex(where: { $0.id == p.id }) {
                profiles[idx] = p
            } else {
                profiles.append(p)
                profiles.sort { $0.createdAt < $1.createdAt }
            }
            scheduleWrite(p)

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

            log.info("Saved profile \(p.name, privacy: .private) (\(p.id.uuidString, privacy: .public))")
        }
    }

    /// Link `profile` to an output device for automatic activation — or pass
    /// nil to unlink — enforcing the one-device-one-profile invariant: any
    /// OTHER profile holding the same link loses it, because the newest link
    /// is the user's current intent. Without this, auto-switch resolved
    /// duplicates by profile age, so a second profile linked to the same
    /// device silently never activated (audit CX-03).
    ///
    /// Returns the profiles whose links were cleared, so callers can tell the
    /// user what moved.
    @discardableResult
    func linkDevice(uid: String?, to profile: HearingProfile) throws -> [HearingProfile] {
        var displaced: [HearingProfile] = []
        if let uid {
            for other in profiles where other.id != profile.id && other.linkedDeviceUID == uid {
                var cleared = other
                cleared.linkedDeviceUID = nil
                try save(cleared, actionName: "Unlink \(other.name)")
                displaced.append(other)
            }
        }
        // Live copy, not the caller's render snapshot (audit CX-05).
        var updated = profiles.first { $0.id == profile.id } ?? profile
        updated.linkedDeviceUID = uid
        try save(updated, actionName: uid == nil ? "Unlink device" : "Link device")
        return displaced
    }

    /// Queue `p` as its profile's latest unwritten snapshot and (re)arm the
    /// trailing debounce. Later snapshots of the same profile replace earlier
    /// ones — only the last state of a burst ever touches the disk.
    private func scheduleWrite(_ p: HearingProfile) {
        pendingWrites[p.id] = p
        pendingFlush?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushPendingWrites() }
        }
        pendingFlush = item
        DispatchQueue.main.asyncAfter(deadline: .now() + writeDebounce, execute: item)
    }

    /// Write every pending snapshot to disk now. The durability point —
    /// called by the debounce, by `loadAll`/`relocate` before they read or
    /// move the directory, and by app termination. Safe to call when nothing
    /// is pending.
    func flushPendingWrites() {
        pendingFlush?.cancel()
        pendingFlush = nil
        guard !pendingWrites.isEmpty else { return }
        let batch = pendingWrites
        pendingWrites = [:]
        for p in batch.values { writeToDisk(p) }
    }

    /// The former inline body of `save(_:)`: atomic temp-write/rename plus
    /// owner-only permissions (profiles encode hearing thresholds). Runs at
    /// most once per profile per debounce window. Failures land in
    /// `lastError` (→ notice banner) — the same surface synchronous save
    /// errors used, just later.
    private func writeToDisk(_ p: HearingProfile) {
        do {
            let data = try encoder.encode(p)
            let url = directory.appendingPathComponent("\(p.id.uuidString).json")
            try data.write(to: url, options: .atomic)
            // Best-effort: a failure here still leaves the directory-level
            // 0700 from `ensureDirectory()` in place.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            log.error("Deferred save of \(p.name, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Encode `profile` to a user-chosen location. Independent of the
    /// internal profiles directory — used for sharing profiles between
    /// machines or with other users.
    ///
    /// Exports are sanitized: `HearingProfile` uses synthesized encoding, so
    /// a raw encode would ship every stored field — including
    /// `autoEQSourcePath` (a local filesystem path that can embed the macOS
    /// username), the exporter's device UIDs/names, and the device link.
    /// None of those mean anything on another machine, and a "share this EQ
    /// preset" file shouldn't disclose who exported it or what hardware they
    /// own. The on-disk save format is unchanged; only exports are filtered.
    /// (Import tolerates the absent fields — they're all optionals.)
    func exportProfile(_ profile: HearingProfile, to url: URL) throws {
        try tracking("Export") {
            let data = try encoder.encode(Self.sanitizedForSharing(profile))
            try data.write(to: url, options: .atomic)
            log.info("Exported \(profile.name, privacy: .private) to \(url.lastPathComponent, privacy: .private)")
        }
    }

    /// Strip machine- and identity-revealing fields for export. The recipient
    /// keeps everything that shapes sound (bands, audiogram, notch, comfort
    /// settings, the AutoEQ correction itself + its `autoEQName`, which lets
    /// their own library re-match it by name). Removed:
    /// - `autoEQSourcePath` — local path from the exporter's file import
    /// - `autoEQDeviceUID` / `autoEQDeviceName` — the exporter's output device
    /// - `linkedDeviceUID` — device-link auto-activation is per-machine
    ///
    /// Cost: a same-machine export/import round trip loses the device link
    /// and mismatch anchor (two clicks to restore). Audiogram/notch data is
    /// intentionally kept — it's the point of sharing a hearing profile.
    static func sanitizedForSharing(_ profile: HearingProfile) -> HearingProfile {
        var shared = profile
        shared.autoEQSourcePath = nil
        shared.autoEQDeviceUID = nil
        shared.autoEQDeviceName = nil
        shared.linkedDeviceUID = nil
        return shared
    }

    /// Read a profile JSON from `url`, dedupe its ID and name against the
    /// current store, force `isBuiltIn = false` (the imported copy is the
    /// user's own), and persist it. Returns the saved profile so callers
    /// can switch selection or activate it.
    /// - Parameter noFollow: when true, read through an `O_NOFOLLOW` open that
    ///   refuses a symlink at the final path component (audit I-1). The CLI
    ///   control port passes this — its caller-supplied path is untrusted and
    ///   the handler's own symlink check is otherwise a separate, raceable step.
    ///   GUI imports leave it false (the file was just picked in an open panel).
    @discardableResult
    func importProfile(from url: URL, noFollow: Bool = false) throws -> HearingProfile {
        try tracking("Import") {
            let data = try noFollow ? FileImportLimit.dataNoFollow(at: url)
                                    : FileImportLimit.data(at: url)
            var imported = try decoder.decode(HearingProfile.self, from: data)
            if profiles.contains(where: { $0.id == imported.id }) {
                imported.id = UUID()
            }
            imported.name = uniqueName(base: imported.name)
            imported.isBuiltIn = false
            try save(imported)
            log.info("Imported \(imported.name, privacy: .private) from \(url.lastPathComponent, privacy: .private)")
            return imported
        }
    }

    /// Encode a standalone audiogram (`AudiogramInterchange` — the HealthKit-
    /// shaped exchange format) to a user-chosen location, independent of any
    /// profile. The portable counterpart to `exportProfile`, for sharing or
    /// backing up just the hearing test.
    func exportAudiogram(_ doc: AudiogramInterchange, to url: URL) throws {
        try tracking("Export audiogram") {
            let data = try encoder.encode(doc)
            try data.write(to: url, options: .atomic)
            log.info("Exported audiogram to \(url.lastPathComponent, privacy: .private)")
        }
    }

    /// Read a standalone audiogram JSON from `url`. Callers apply it onto a
    /// profile via `HearingProfile.applyingAudiogram(_:modifiedAt:)` and save.
    func importAudiogram(from url: URL) throws -> AudiogramInterchange {
        try tracking("Import audiogram") {
            let data = try FileImportLimit.data(at: url)
            return try decoder.decode(AudiogramInterchange.self, from: data)
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
            // Drop any unwritten snapshot first — otherwise the debounce could
            // fire after this delete and resurrect the file from memory.
            pendingWrites[profile.id] = nil
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

            log.info("Deleted profile \(profile.name, privacy: .private)")
        }
    }

    // MARK: - Factory listening presets

    /// Bumped whenever the shipped factory-preset set changes. A launch that
    /// sees a lower stored version runs the one-time reconcile below.
    /// v2 (phase3-make-correction-land.md §3): presets re-voiced on the
    /// 12-band grid via the shared `PresetCurve` table; Presence Boost
    /// retired and replaced by Reduce Boom.
    private static let factoryPresetsVersion = 3
    private static let factoryPresetsVersionKey = "sherlockeq.factoryPresetsVersion"

    private static let retiredGraphicMigrationKey = "sherlockeq.retiredGraphicBandsMigrated"

    /// Centers the Graphic surface no longer has sliders for, as of the 12 → 10
    /// return to the ISO octave grid.
    private static let retiredGraphicCenters: [Double] = [3000, 6000]

    /// Fold any 3 kHz / 6 kHz manual bands into the surviving sliders.
    ///
    /// `reconcileFactoryPresets` handles presets the user never touched by
    /// replacing them outright. Everything else — user profiles, and presets
    /// with any edit at all — keeps whatever bands it had, which after this
    /// change includes two the Graphic screen can't edit. Left alone they'd
    /// surface in the "Other filters" row: an orange warning about bands the
    /// app itself wrote, offering to convert away settings the user chose.
    ///
    /// So convert them here instead, with the same `GraphicConversion` fit that
    /// backs that row's button. Its own documentation gives the property this
    /// relies on: because cascade magnitudes add in dB, fitting the retired
    /// bands *alone* and adding the result to the current slider gains is exact
    /// up to the fit error. The profile keeps sounding like itself.
    ///
    /// Gated on its own key so it runs exactly once. Profiles with nothing at
    /// 3 k or 6 k are not touched at all — no `modifiedAt` bump, nothing marked
    /// edited.
    func migrateRetiredGraphicBandsIfNeeded() {
        guard !defaults.bool(forKey: Self.retiredGraphicMigrationKey) else { return }
        defer { defaults.set(true, forKey: Self.retiredGraphicMigrationKey) }

        var converted = 0
        for profile in profiles {
            var updated = profile
            var touched = false
            for keyPath in [\HearingProfile.leftEar, \HearingProfile.rightEar] {
                if Self.foldRetiredBands(in: &updated[keyPath: keyPath].bands) { touched = true }
            }
            guard touched else { continue }
            do {
                try save(updated)
                converted += 1
            } catch {
                log.error("Retired-band migration failed for \(profile.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        log.info("Folded retired 3k/6k bands on \(converted, privacy: .public) profile(s)")
    }

    /// Returns true if anything was folded.
    private static func foldRetiredBands(in bands: inout [EQBand]) -> Bool {
        let retired = bands.filter { band in
            band.filterType == .parametric
                && retiredGraphicCenters.contains { abs(band.frequencyHz - $0) < 0.5 }
        }
        guard !retired.isEmpty else { return false }

        // Their combined contribution, expressed on the surviving grid.
        let contribution = GraphicConversion.fittedGains(for: retired.filter(\.enabled))

        bands.removeAll { retiredBand in retired.contains { $0.id == retiredBand.id } }
        for (center, delta) in zip(EQMode.graphicCenters, contribution) where delta != 0 {
            let current = EQBandLookup.gain(at: center, filterType: .parametric, in: bands)
            EQBandLookup.setGain(current + delta, at: center, bandwidth: 1.0,
                                 filterType: .parametric, in: &bands)
        }
        return true
    }

    private static let autoEQScopeMigrationKey = "sherlockeq.autoEQScopeMigrated"
    private static let legacyGlobalAutoEQKey = "sherlockeq.autoEQEnabled"

    /// One-time move of the AutoEQ on/off switch from a single app-wide
    /// preference onto each profile.
    ///
    /// The flag now defaults to `true` when decoding, which is right for the
    /// overwhelming majority — but wrong for anyone who had deliberately
    /// switched the old global off. For them, a silent default would turn a
    /// bypassed correction back on the first time they launched the new
    /// build: headphone EQ they had chosen to disable, re-applied without a
    /// word. So carry the old value across before it stops being consulted.
    ///
    /// Gated on its own key rather than the app version so it runs exactly
    /// once, and only stamps profiles that actually carry a correction —
    /// there is nothing to bypass on the others, and marking them edited
    /// would be a lie.
    func migrateAutoEQScopeIfNeeded() {
        guard !defaults.bool(forKey: Self.autoEQScopeMigrationKey) else { return }
        defer { defaults.set(true, forKey: Self.autoEQScopeMigrationKey) }

        // Absent key → the user never touched it → it was on → nothing to do.
        guard defaults.object(forKey: Self.legacyGlobalAutoEQKey) != nil,
              defaults.bool(forKey: Self.legacyGlobalAutoEQKey) == false else { return }

        var carried = 0
        for profile in profiles where !(profile.autoEQBands?.isEmpty ?? true) {
            var updated = profile
            updated.autoEQEnabled = false
            do {
                try save(updated)
                carried += 1
            } catch {
                log.error("AutoEQ scope migration failed for \(profile.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        // The global is now a Debug-only per-stage bypass. Leave it off only
        // if we failed to carry the intent onto any profile, so the user's
        // correction can't come back on behind their back.
        if carried > 0 {
            defaults.set(true, forKey: Self.legacyGlobalAutoEQKey)
        }
        log.info("Migrated AutoEQ bypass onto \(carried, privacy: .public) profile(s)")
    }

    /// The complete v1 factory-preset definitions, frozen for the v1 → v2
    /// migration's edit detection (spec Design note 3). Comparing a stored
    /// preset against the CURRENT builders is circular — after a re-voicing,
    /// every untouched preset "differs" — so upgrade decisions compare
    /// against these exact shipped-v1 values instead. Full profiles (not
    /// just gains) so an edit anywhere — a renamed preset, an added
    /// audiogram or notch — reads as user work and is preserved.
    /// Internal (not private) so migration tests can seed exact v1 state.
    enum FrozenFactoryV1 {
        static let presenceBoostID = UUID(uuidString: "F0000004-0000-4000-A000-000000000004")!

        /// v1 authoring grid (pre-3k/6k).
        private static let centers: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

        private static func bands(_ gains: [Double]) -> [EQBand] {
            zip(centers, gains).map { freq, gain in
                EQBand(frequencyHz: freq, gaindB: gain, bandwidth: 1.0, filterType: .parametric, enabled: true)
            }
        }

        private static func profile(
            id: UUID, orderIndex: Int, name: String, symbol: String,
            gains: [Double], trimDB: Double, description: String, tags: [String]
        ) -> HearingProfile {
            let stamp = Date(timeIntervalSince1970: 1_600_000_000 + Double(orderIndex))
            let b = bands(gains)
            return HearingProfile(
                id: id, name: name, symbol: symbol, linkedDeviceUID: nil,
                leftEar: EarProfile(thresholds: AudiogramPoint.flat, bands: b),
                rightEar: EarProfile(thresholds: AudiogramPoint.flat, bands: b),
                leftNotch: .disabled, rightNotch: .disabled,
                globalTrimDB: trimDB, safeListeningCeilingDB: 85.0,
                compensationFactor: 0.5, eqMode: .advanced, isBuiltIn: true,
                presetDescription: description, presetTags: tags,
                createdAt: stamp, modifiedAt: stamp
            )
        }

        static let profiles: [HearingProfile] = [
            profile(
                id: HearingProfile.Factory.voiceClarity.id, orderIndex: 0,
                name: "Voice Clarity", symbol: "waveform.badge.mic",
                gains: [-4, -3, -2, -1, 0, 1, 2, 2.5, 0.5, -1], trimDB: -2,
                description: "Improves spoken-word clarity by reducing low-frequency boom and gently increasing speech presence. Best for podcasts, calls, meetings, lectures, and audiobooks.",
                tags: ["Voice", "Speech", "Clarity"]),
            profile(
                id: HearingProfile.Factory.musicBalanced.id, orderIndex: 1,
                name: "Music Balanced", symbol: "music.note",
                gains: [0.5, 1, 0.5, -0.5, 0, 0, 0.5, 1, 0, -0.5], trimDB: -1,
                description: "A natural, lightly refined music profile with modest bass support and gentle clarity. Designed to preserve the character of music without making it overly bright.",
                tags: ["Music", "Balanced", "Natural"]),
            profile(
                id: HearingProfile.Factory.gentleListening.id, orderIndex: 2,
                name: "Gentle Listening", symbol: "moon.stars",
                gains: [0, 0, 0.5, 0.5, 0, 0, -0.5, -1.5, -2.5, -3], trimDB: 0,
                description: "Softens bright or fatiguing audio for longer, more comfortable listening. Useful for sharp headphones, late-night sessions, or content that feels harsh.",
                tags: ["Comfort", "Soft", "Long Sessions"]),
            profile(
                id: presenceBoostID, orderIndex: 3,
                name: "Presence Boost", symbol: "sparkles",
                gains: [-1, -1, -1, -0.5, 0, 0.5, 1.5, 2, 0.5, 0], trimDB: -2,
                description: "Adds mild definition and presence for audio that sounds dull or veiled. Conservative by design and not a substitute for an audiogram-based profile.",
                tags: ["Clarity", "Presence", "Mild Lift"]),
        ]

        /// True when `stored` is byte-for-audibly identical to the v1
        /// factory definition with the same id — i.e. the user never
        /// touched it and the migration may replace it.
        static func isUneditedV1(_ stored: HearingProfile) -> Bool {
            guard let v1 = profiles.first(where: { $0.id == stored.id }) else { return false }
            return ProfileStore.profile(stored, matchesCanonical: v1)
        }
    }

    /// The v2 factory definitions, frozen for the v2 → v3 migration's edit
    /// detection — same role `FrozenFactoryV1` plays for v1 → v2, and needed
    /// for the same reason: comparing a stored preset against the *current*
    /// builders is circular once the grid changes underneath them.
    ///
    /// Without this, anyone whose presets were already pristine on v2 would
    /// fail `isUneditedV1` (their gains are v2's, not v1's), be treated as
    /// edited, and keep 12-band presets whose 3 kHz and 6 kHz bands the new
    /// grid can't edit — surfacing as an "Other filters" warning about bands
    /// the app itself wrote.
    enum FrozenFactoryV2 {
        /// v2 authoring grid — the 10 ISO octaves plus 3 k and 6 k. v3 drops
        /// those two again, returning to v1's grid with v2's voicing resampled
        /// onto it.
        private static let centers: [Double] =
            [31.5, 63, 125, 250, 500, 1000, 2000, 3000, 4000, 6000, 8000, 16000]

        private static func bands(_ gains: [Double]) -> [EQBand] {
            zip(centers, gains).map { freq, gain in
                EQBand(frequencyHz: freq, gaindB: gain, bandwidth: 1.0,
                       filterType: .parametric, enabled: true)
            }
        }

        /// v2 curve tables, verbatim from `PresetCurve.gains` before the
        /// resample. Duplicated rather than referenced on purpose: the point
        /// of a frozen set is that it stops tracking the live definitions.
        private static let curves: [(id: UUID, orderIndex: Int, name: String, symbol: String,
                                     gains: [Double], trimDB: Double,
                                     description: String, tags: [String])] = [
            (HearingProfile.Factory.voiceClarity.id, 0, "Voice Clarity", "waveform.badge.mic",
             [-4, -3, -2, -1, 0, 1, 2, 2.5, 3, 2, 1, -1], -2,
             "Voices are hard to follow — lifts speech presence and consonant detail while trimming the low-frequency boom that masks them. Best for podcasts, calls, meetings, and audiobooks.",
             ["Voice", "Speech", "Clarity"]),
            (HearingProfile.Factory.musicBalanced.id, 1, "Music Balanced", "music.note",
             [1.5, 2, 1, -0.5, -0.5, 0, 1, 1.5, 1.5, 1, 0.5, 0], -1,
             "The everyday starting point — light warmth, less low-mid mud, and a gentle clarity lift. Audible against Reference Mode without imposing a strong flavor.",
             ["Music", "Everyday", "Balanced"]),
            (HearingProfile.Factory.gentleListening.id, 2, "Gentle Listening", "moon.stars",
             [0, 0, 0.5, 0.5, 0, 0, -0.5, -1, -2, -3, -3.5, -4.5], 0,
             "Audio feels sharp or tiring — progressively softens the highs for long, comfortable sessions, sharp headphones, and late-night listening.",
             ["Comfort", "Soft", "Long Sessions"]),
            (HearingProfile.Factory.reduceBoom.id, 3, "Reduce Boom", "speaker.minus",
             [-3, -2.5, -2, -1.5, -0.5, 0, 0.5, 0.5, 0, 0, 0, 0], 0,
             "Audio sounds boomy or muddy — tightens the low end so voices and detail come through. Good for boomy rooms, small speakers, and bass-heavy headphones.",
             ["Clarity", "Low End", "Small Speakers"]),
        ]

        static let profiles: [HearingProfile] = curves.map { c in
            let stamp = Date(timeIntervalSince1970: 1_600_000_000 + Double(c.orderIndex))
            let b = bands(c.gains)
            return HearingProfile(
                id: c.id, name: c.name, symbol: c.symbol, linkedDeviceUID: nil,
                leftEar: EarProfile(thresholds: AudiogramPoint.flat, bands: b),
                rightEar: EarProfile(thresholds: AudiogramPoint.flat, bands: b),
                leftNotch: .disabled, rightNotch: .disabled,
                globalTrimDB: c.trimDB, safeListeningCeilingDB: 85.0,
                compensationFactor: 0.5, eqMode: .advanced, isBuiltIn: true,
                presetDescription: c.description, presetTags: c.tags,
                createdAt: stamp, modifiedAt: stamp
            )
        }

        static func isUneditedV2(_ stored: HearingProfile) -> Bool {
            guard let v2 = profiles.first(where: { $0.id == stored.id }) else { return false }
            return ProfileStore.profile(stored, matchesCanonical: v2)
        }
    }

    private var storedFactoryVersion: Int {
        get { defaults.integer(forKey: Self.factoryPresetsVersionKey) }
        set { defaults.set(newValue, forKey: Self.factoryPresetsVersionKey) }
    }

    private var factoryIDs: Set<UUID> { Set(HearingProfile.factoryProfiles.map(\.id)) }

    /// One-time-per-version migration. Gated on `factoryPresetsVersion` so
    /// a preset the user deliberately deleted is NOT silently re-added on
    /// every launch — only on a genuine version bump. Three rules, in the
    /// spirit of "never clobber a user edit" (spec Design note 3):
    ///
    /// 1. **Retired/legacy built-ins** (ids outside the canonical set —
    ///    Presence Boost after v2, ancient random-id Default/Voice Clarity):
    ///    deleted when they exactly match a frozen shipped definition
    ///    (pristine — nothing of the user's is lost); otherwise **demoted**
    ///    to a plain user profile (star and factory affordances removed,
    ///    every edit preserved).
    /// 2. **Canonical presets present by id**: replaced with the current
    ///    version only when still pristine-v1; an edited one is left
    ///    entirely alone ("Reset to Factory Default" now targets v2).
    /// 3. **Canonical presets missing**: installed.
    func reconcileFactoryPresets() {
        guard storedFactoryVersion < Self.factoryPresetsVersion else { return }
        do {
            let canonicalIDs = factoryIDs
            for legacy in profiles where legacy.isBuiltIn && !canonicalIDs.contains(legacy.id) {
                if FrozenFactoryV1.isUneditedV1(legacy) {
                    try delete(legacy)
                } else {
                    var demoted = legacy
                    demoted.isBuiltIn = false
                    demoted.presetDescription = nil
                    demoted.presetTags = []
                    try save(demoted)
                    log.info("Demoted edited retired preset \(demoted.name, privacy: .private) to user profile")
                }
            }
            for preset in HearingProfile.factoryProfiles {
                if let stored = profiles.first(where: { $0.id == preset.id }) {
                    // Pristine on ANY previously-shipped grid → adopt the
                    // current one. v2 has to be checked as well as v1: after
                    // the 12→10 band change, a preset left on v2's grid keeps
                    // 3 k/6 k bands the Graphic screen can no longer edit.
                    if FrozenFactoryV1.isUneditedV1(stored) || FrozenFactoryV2.isUneditedV2(stored) {
                        try save(preset)
                    }
                    // edited → leave alone
                } else {
                    try save(preset)       // missing → install on version bump
                }
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
            log.info("Reset \(canonical.name, privacy: .private) to factory default")
        } catch {
            lastError = "Could not reset profile: \(error.localizedDescription)"
            log.error("Factory reset failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// True when `profile` is a factory preset whose current values differ
    /// from its shipped canonical version — drives the "Reset to Factory
    /// Default" button's enabled state.
    ///
    /// The band arrays are checked with `audiblyEquivalent` so float noise from
    /// a save/edit round-trip doesn't read as a change. Everything else (the
    /// audiogram thresholds + derived correction, tinnitus notch, compensation
    /// strength, AutoEQ, dynamics, EQ mode, trim, balance, name, …) is compared
    /// by value via the synthesized `==`, after neutralising the already-checked
    /// bands and the always-differing timestamps. Comparing the whole struct
    /// this way means a new editable field is covered automatically instead of
    /// silently leaving the Reset button disabled.
    func differsFromFactory(_ profile: HearingProfile) -> Bool {
        guard let canonical = HearingProfile.factoryCanonical(forID: profile.id) else { return false }
        return !Self.profile(profile, matchesCanonical: canonical)
    }

    /// Value-equality between a stored profile and a canonical definition,
    /// ignoring the always-differing timestamps and comparing band arrays
    /// with `audiblyEquivalent` (band UUIDs are minted fresh per save, and
    /// float noise from an edit round-trip shouldn't read as a change).
    /// Shared by `differsFromFactory` (against current builders) and the
    /// v1 → v2 migration's edit detection (against `FrozenFactoryV1`).
    static func profile(_ profile: HearingProfile, matchesCanonical canonical: HearingProfile) -> Bool {
        if !profile.leftEar.bands.audiblyEquivalent(to: canonical.leftEar.bands) { return false }
        if !profile.rightEar.bands.audiblyEquivalent(to: canonical.rightEar.bands) { return false }
        var a = profile, b = canonical
        a.createdAt = b.createdAt
        a.modifiedAt = b.modifiedAt
        // Bands already compared with tolerance above — blank them so the
        // struct compare below can't re-flag the same float noise.
        a.leftEar.bands = []; b.leftEar.bands = []
        a.rightEar.bands = []; b.rightEar.bands = []
        return a == b
    }

    // MARK: - Helpers

    var storageDirectory: URL { directory }

    private func ensureDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            do {
                // Owner-only: profiles can encode a user's hearing thresholds.
                try fm.createDirectory(at: directory,
                                       withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
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
        } else {
            // Tighten an existing directory — installs from before 0.6.4
            // created it with the umask default (typically 0755). Best-effort.
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        excludeFromBackup(directory)
    }

    /// Exclude a directory (and, per Time Machine's documented behavior,
    /// everything under it) from Time Machine and other backup tools that
    /// honor the same resource value. Profiles encode audiogram thresholds
    /// and tinnitus settings — health data that shouldn't accumulate in
    /// historical backups a user has no way to purge from within the app.
    /// Best-effort and idempotent — safe to call on every launch.
    private func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
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
    static func bootDirectory(defaults: UserDefaults = .standard) -> URL {
        if let path = defaults.string(forKey: directoryOverrideKey),
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
                defaults.removeObject(forKey: directoryOverrideKey)
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
            // Land pending snapshots before enumerating/moving the old
            // directory, so in-flight edits relocate with everything else.
            flushPendingWrites()
            let oldDirectory = directory
            if newDirectory.standardizedFileURL == oldDirectory.standardizedFileURL {
                throw RelocationError.sourceIsDestination
            }

            let fm = FileManager.default
            if !fm.fileExists(atPath: newDirectory.path) {
                try fm.createDirectory(at: newDirectory,
                                       withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
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
                defaults.removeObject(forKey: Self.directoryOverrideKey)
            } else {
                defaults.set(newDirectory.path, forKey: Self.directoryOverrideKey)
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
