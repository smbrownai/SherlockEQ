//
//  ProfileStoreTests.swift
//  SherlockEQTests
//
//  Persistence + relocation + import-dedup behaviours, driven against
//  a per-test temporary directory so nothing touches the user's real
//  Application Support folder.
//

import Testing
import Foundation
@testable import SherlockEQ

@MainActor
struct ProfileStoreTests {

    // MARK: - Helpers

    /// Create a unique scratch dir per test. Caller is responsible for
    /// instantiating the store with this URL.
    private static func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SherlockEQTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// A throwaway defaults suite, one per test. These tests run hosted in
    /// the app (TEST_HOST), so `UserDefaults.standard` IS the production
    /// `com.shawnbrown.SherlockEQ` domain — a leaked key once pointed the
    /// real app at a reboot-purged temp dir (see `bootDirectory()`'s
    /// self-heal). Injecting a scratch suite makes that pollution
    /// structurally impossible (audit TD-02). `cleanup()` deletes the plist
    /// the suite may have materialized.
    private struct ScratchDefaults {
        let suite = "SherlockEQTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        init() { defaults = UserDefaults(suiteName: suite)! }
        func cleanup() { defaults.removePersistentDomain(forName: suite) }
    }

    private static func makeStore(at url: URL, defaults: UserDefaults? = nil) -> ProfileStore {
        ProfileStore(directory: url, defaults: defaults ?? ScratchDefaults().defaults)
    }

    // MARK: - Save / load round-trip

    @Test func saveThenLoadRoundTrip() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }

        let store = Self.makeStore(at: dir)
        let original = HearingProfile.makeDefault(name: "Round-trip")
        try store.save(original)
        store.flushPendingWrites()   // durability point — writes are debounced

        // Fresh store reading the same dir sees the saved file.
        let fresh = Self.makeStore(at: dir)
        let loaded = fresh.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == original.id)
        #expect(loaded[0].name == "Round-trip")
    }

    @Test func savedProfileFileHasOwnerOnlyPermissions() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }

        let store = Self.makeStore(at: dir)
        let profile = HearingProfile.makeDefault(name: "Perm check")
        try store.save(profile)
        store.flushPendingWrites()

        let url = dir.appendingPathComponent("\(profile.id.uuidString).json")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let posix = attrs[.posixPermissions] as? NSNumber
        #expect(posix?.intValue == 0o600)
    }

    @Test func profilesDirectoryIsExcludedFromBackup() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }

        let store = Self.makeStore(at: dir)
        try store.save(HearingProfile.makeDefault(name: "Backup check"))
        store.flushPendingWrites()

        let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func loadingDirectoryWithoutProfilesReturnsEmpty() {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }

        let store = Self.makeStore(at: dir)
        #expect(store.loadAll().isEmpty)
    }

    // MARK: - Delete

    @Test func deleteRemovesProfileFromDiskAndMemory() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }

        let store = Self.makeStore(at: dir)
        let p = HearingProfile.makeDefault(name: "To be deleted")
        try store.save(p)
        store.flushPendingWrites()
        #expect(store.profiles.count == 1)

        try store.delete(p)
        #expect(store.profiles.isEmpty)

        // Confirm the disk is empty too.
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(urls.filter { $0.pathExtension == "json" }.isEmpty)
    }

    // MARK: - Factory presets

    /// The version gate is read from the store's injected defaults; seed it
    /// per test so each starts "pre-migration" and the gated reconcile
    /// actually runs.
    private static let factoryVersionKey = "sherlockeq.factoryPresetsVersion"

    @Test func reconcileInstallsFourFactoryPresetsInOrder() {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let scratch = ScratchDefaults()
        defer { scratch.cleanup() }
        scratch.defaults.set(0, forKey: Self.factoryVersionKey)

        let store = Self.makeStore(at: dir, defaults: scratch.defaults)
        store.reconcileFactoryPresets()
        #expect(store.profiles.map(\.name) == ["Voice Clarity", "Music Balanced", "Gentle Listening", "Reduce Boom"])
        #expect(store.profiles.allSatisfy { $0.isBuiltIn })
        #expect(store.profiles.allSatisfy { $0.eqMode == .advanced })
        #expect(store.profiles.allSatisfy { $0.leftEar.bands.count == 12 })
    }

    @Test func reconcileDemotesUnknownLegacyBuiltIns() throws {
        // An unrecognizable built-in (random id, doesn't match any frozen
        // shipped definition) might carry user edits we can't detect —
        // v2's rule demotes it to a user profile instead of deleting it.
        // (The v1 delete-on-sight rule once wiped a user's edited Default.)
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let scratch = ScratchDefaults()
        defer { scratch.cleanup() }
        scratch.defaults.set(0, forKey: Self.factoryVersionKey)

        let store = Self.makeStore(at: dir, defaults: scratch.defaults)
        try store.save(.makeDefault(name: "Default", isBuiltIn: true)) // legacy random-id built-in
        store.reconcileFactoryPresets()
        let demoted = try #require(store.profiles.first { $0.name == "Default" })
        #expect(!demoted.isBuiltIn)
        #expect(store.profiles.count == 5)   // four factory + the demoted legacy
    }

    // MARK: - v1 → v2 factory upgrade (phase3-make-correction-land.md §3.4)

    /// Seed the store as a v1 install: the four v1 factory presets on disk
    /// and the version gate at 1.
    private static func seedV1(_ store: ProfileStore, defaults: UserDefaults) throws {
        for v1 in ProfileStore.FrozenFactoryV1.profiles {
            try store.save(v1)
        }
        defaults.set(1, forKey: factoryVersionKey)
    }

    @Test func upgradeReplacesPristineV1PresetsAndRetiresPresenceBoost() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let scratch = ScratchDefaults()
        defer { scratch.cleanup() }

        let store = Self.makeStore(at: dir, defaults: scratch.defaults)
        try Self.seedV1(store, defaults: scratch.defaults)
        store.reconcileFactoryPresets()

        // Pristine v1 presets upgraded in place to the 12-band v2 voicings.
        let mb = try #require(store.profiles.first { $0.id == HearingProfile.Factory.musicBalanced.id })
        #expect(mb.leftEar.bands.count == 12)
        #expect(!store.differsFromFactory(mb))
        // Presence Boost (pristine) retired; Reduce Boom installed.
        #expect(!store.profiles.contains { $0.id == ProfileStore.FrozenFactoryV1.presenceBoostID })
        #expect(store.profiles.contains { $0.id == HearingProfile.Factory.reduceBoom.id })
        #expect(store.profiles.count == 4)
    }

    @Test func upgradeLeavesEditedV1PresetAlone() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let scratch = ScratchDefaults()
        defer { scratch.cleanup() }

        let store = Self.makeStore(at: dir, defaults: scratch.defaults)
        try Self.seedV1(store, defaults: scratch.defaults)
        // User edited Music Balanced's 1 kHz band in v1.
        var edited = try #require(store.profiles.first { $0.id == HearingProfile.Factory.musicBalanced.id })
        EQBandLookup.mutateBothEars(of: &edited) { bands in
            EQBandLookup.setGain(5, at: 1000, bandwidth: 1.0, filterType: .parametric, in: &bands)
        }
        try store.save(edited)

        store.reconcileFactoryPresets()

        // The edit survives — still the v1 shape with the user's value.
        let mb = try #require(store.profiles.first { $0.id == HearingProfile.Factory.musicBalanced.id })
        #expect(EQBandLookup.gain(at: 1000, filterType: .parametric, in: mb.leftEar.bands) == 5)
        #expect(mb.isBuiltIn)   // still a factory preset; Reset targets v2 now
        // The untouched presets upgraded around it.
        let vc = try #require(store.profiles.first { $0.id == HearingProfile.Factory.voiceClarity.id })
        #expect(vc.leftEar.bands.count == 12)
    }

    @Test func upgradeDemotesEditedPresenceBoost() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let scratch = ScratchDefaults()
        defer { scratch.cleanup() }

        let store = Self.makeStore(at: dir, defaults: scratch.defaults)
        try Self.seedV1(store, defaults: scratch.defaults)
        var editedPB = try #require(store.profiles.first { $0.id == ProfileStore.FrozenFactoryV1.presenceBoostID })
        EQBandLookup.mutateBothEars(of: &editedPB) { bands in
            EQBandLookup.setGain(-4, at: 8000, bandwidth: 1.0, filterType: .parametric, in: &bands)
        }
        try store.save(editedPB)

        store.reconcileFactoryPresets()

        // The user's edited Presence Boost survives as their own profile.
        let demoted = try #require(store.profiles.first { $0.id == ProfileStore.FrozenFactoryV1.presenceBoostID })
        #expect(!demoted.isBuiltIn)
        #expect(demoted.presetDescription == nil)
        #expect(EQBandLookup.gain(at: 8000, filterType: .parametric, in: demoted.leftEar.bands) == -4)
        // And the new factory set is fully installed alongside it.
        #expect(store.profiles.filter(\.isBuiltIn).count == 4)
    }

    @Test func reconcileDoesNotReAddDeletedPresetAtSameVersion() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let scratch = ScratchDefaults()
        defer { scratch.cleanup() }
        scratch.defaults.set(0, forKey: Self.factoryVersionKey)

        let store = Self.makeStore(at: dir, defaults: scratch.defaults)
        store.reconcileFactoryPresets()                       // installs 4, bumps version
        let gentle = try #require(store.profiles.first { $0.name == "Gentle Listening" })
        try store.delete(gentle)
        store.reconcileFactoryPresets()                       // version current → no-op
        #expect(store.profiles.count == 3)
        #expect(!store.profiles.contains { $0.name == "Gentle Listening" })
    }

    @Test func restoreFactoryPresetsRecreatesDeleted() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let scratch = ScratchDefaults()
        defer { scratch.cleanup() }
        scratch.defaults.set(0, forKey: Self.factoryVersionKey)

        let store = Self.makeStore(at: dir, defaults: scratch.defaults)
        store.reconcileFactoryPresets()
        let gentle = try #require(store.profiles.first { $0.name == "Gentle Listening" })
        try store.delete(gentle)
        store.restoreFactoryPresets()
        #expect(store.profiles.count == 4)
        #expect(store.profiles.contains { $0.name == "Gentle Listening" })
    }

    @Test func resetProfileToFactoryRestoresValues() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let scratch = ScratchDefaults()
        defer { scratch.cleanup() }
        scratch.defaults.set(0, forKey: Self.factoryVersionKey)

        let store = Self.makeStore(at: dir, defaults: scratch.defaults)
        store.reconcileFactoryPresets()
        var vc = try #require(store.profiles.first { $0.name == "Voice Clarity" })
        let id = vc.id
        #expect(!store.differsFromFactory(vc))   // pristine
        vc.leftEar.bands[0].gaindB = 11          // tamper
        vc.globalTrimDB = 5
        try store.save(vc)
        #expect(store.differsFromFactory(try #require(store.profiles.first { $0.id == id })))

        store.resetProfileToFactory(id)
        let restored = try #require(store.profiles.first { $0.id == id })
        #expect(!store.differsFromFactory(restored))
        let canonical = HearingProfile.factoryVoiceClarity()
        #expect(restored.leftEar.bands.audiblyEquivalent(to: canonical.leftEar.bands))
        #expect(restored.globalTrimDB == canonical.globalTrimDB)
    }

    /// Regression: a factory preset whose audiogram or compensation strength
    /// was changed must report `differsFromFactory` so "Reset to Factory
    /// Default" stays enabled. Previously only band/trim/name/balance edits
    /// were detected, so an audiogram change silently disabled the button.
    @Test func differsFromFactoryDetectsAudiogramAndCompensationEdits() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let scratch = ScratchDefaults()
        defer { scratch.cleanup() }
        scratch.defaults.set(0, forKey: Self.factoryVersionKey)

        let store = Self.makeStore(at: dir, defaults: scratch.defaults)
        store.reconcileFactoryPresets()
        var vc = try #require(store.profiles.first { $0.name == "Voice Clarity" })
        let id = vc.id
        #expect(!store.differsFromFactory(vc))   // pristine

        // Audiogram edit only (bands left alone) — was a false negative before.
        vc.leftEar.thresholds[0].thresholddBHL = 40
        try store.save(vc)
        #expect(store.differsFromFactory(try #require(store.profiles.first { $0.id == id })))

        // Reset clears it again.
        store.resetProfileToFactory(id)
        #expect(!store.differsFromFactory(try #require(store.profiles.first { $0.id == id })))

        // A compensation-strength change alone is also detected.
        var vc2 = try #require(store.profiles.first { $0.id == id })
        vc2.compensationFactor = 0.9
        try store.save(vc2)
        #expect(store.differsFromFactory(try #require(store.profiles.first { $0.id == id })))
    }

    @Test func resetIsNoOpForUserProfiles() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }

        let store = Self.makeStore(at: dir)
        let user = HearingProfile.makeDefault(name: "Mine")
        try store.save(user)
        store.resetProfileToFactory(user.id)   // not a factory id → no change
        #expect(store.profiles.count == 1)
        #expect(store.profiles[0].name == "Mine")
    }

    // MARK: - Import / Export

    @Test func exportThenImportProducesEquivalentProfile() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }

        let exportURL = dir.appendingPathComponent("export.json")
        let store = Self.makeStore(at: dir)
        let original = HearingProfile.makeDefault(name: "Source")
        try store.save(original)
        try store.exportProfile(original, to: exportURL)
        #expect(FileManager.default.fileExists(atPath: exportURL.path))

        // Import into a fresh store directory — verify the round-trip
        // carries through every field we care about.
        let otherDir = Self.makeTempDir()
        defer { Self.cleanup(otherDir) }
        let other = Self.makeStore(at: otherDir)
        let imported = try other.importProfile(from: exportURL)
        #expect(imported.name == "Source")
        #expect(imported.leftEar.bands.audiblyEquivalent(to: original.leftEar.bands))
    }

    /// Exports are for sharing, and hearing data is health-adjacent — the
    /// file must not also carry fields that identify the exporter's machine:
    /// `autoEQSourcePath` (a local path that can embed the macOS username),
    /// the exporter's device UID/name, or the device link. Everything that
    /// shapes sound (including the AutoEQ correction and its name, which lets
    /// the recipient's library re-match it) must survive. The INTERNAL save
    /// format is deliberately unfiltered — losing those fields on relaunch
    /// would break AutoEQ re-matching and device-linked activation locally.
    @Test func exportStripsMachineIdentifyingFieldsButSaveKeepsThem() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }

        let store = Self.makeStore(at: dir)
        var original = HearingProfile.makeDefault(name: "Share me")
        original.autoEQSourcePath = "/Users/someone/Downloads/HD650 ParametricEQ.txt"
        original.autoEQDeviceUID = "device-uid-1234"
        original.autoEQDeviceName = "RODECaster Pro II"
        original.linkedDeviceUID = "linked-uid-5678"
        original.autoEQName = "Sennheiser HD650"
        original.autoEQPreampDB = -3.5
        try store.save(original)
        store.flushPendingWrites()

        // Export into a SEPARATE directory: the store's loadAll() decodes
        // every .json in its own dir, so an export dropped there would load
        // as a second profile with the same id and make the reload
        // assertions below depend on an unstable sort.
        let exportDir = Self.makeTempDir()
        defer { Self.cleanup(exportDir) }
        let exportURL = exportDir.appendingPathComponent("shared.json")
        try store.exportProfile(original, to: exportURL)
        // Mirror the store's decoder config — profile dates are ISO-8601.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exported = try decoder.decode(
            HearingProfile.self, from: Data(contentsOf: exportURL))
        #expect(exported.autoEQSourcePath == nil)
        #expect(exported.autoEQDeviceUID == nil)
        #expect(exported.autoEQDeviceName == nil)
        #expect(exported.linkedDeviceUID == nil)
        #expect(exported.autoEQName == "Sennheiser HD650")
        #expect(exported.autoEQPreampDB == -3.5)
        #expect(exported.name == "Share me")

        // The raw bytes shouldn't mention the fields at all (an explicit
        // `"autoEQSourcePath": null` would still advertise the schema, but
        // more importantly must not carry the path).
        let raw = String(decoding: try Data(contentsOf: exportURL), as: UTF8.self)
        #expect(!raw.contains("/Users/someone"))
        #expect(!raw.contains("device-uid-1234"))
        #expect(!raw.contains("linked-uid-5678"))

        // Internal persistence keeps everything — sanitizing is export-only.
        let fresh = Self.makeStore(at: dir)
        let reloaded = try #require(fresh.loadAll().first { $0.id == original.id })
        #expect(reloaded.autoEQSourcePath == original.autoEQSourcePath)
        #expect(reloaded.autoEQDeviceUID == "device-uid-1234")
        #expect(reloaded.linkedDeviceUID == "linked-uid-5678")
    }

    @Test func importDedupesIDAgainstExisting() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }

        let store = Self.makeStore(at: dir)
        let p = HearingProfile.makeDefault(name: "Same ID")
        try store.save(p)
        let exportURL = dir.appendingPathComponent("export.json")
        try store.exportProfile(p, to: exportURL)

        // Importing the SAME file back should produce a different ID
        // (the store mints a fresh UUID to avoid clobbering the
        // existing profile).
        let imported = try store.importProfile(from: exportURL)
        #expect(imported.id != p.id)
        #expect(store.profiles.count == 2)
    }

    @Test func importDedupesNameAgainstExisting() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }

        let store = Self.makeStore(at: dir)
        let p = HearingProfile.makeDefault(name: "Duplicate")
        try store.save(p)
        let exportURL = dir.appendingPathComponent("export.json")
        try store.exportProfile(p, to: exportURL)

        let imported = try store.importProfile(from: exportURL)
        // Names diverge — the imported copy gets a suffix.
        #expect(imported.name != "Duplicate")
        #expect(imported.name.hasPrefix("Duplicate"))
    }

    @Test func importForcesIsBuiltInToFalse() throws {
        // Imported profiles must NOT inherit `isBuiltIn = true` — that
        // would let a malicious file pretend to be a curated preset
        // and dodge the UI's "duplicate to edit" guard.
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }

        let store = Self.makeStore(at: dir)
        var builtIn = HearingProfile.makeDefault(name: "Pretender", isBuiltIn: true)
        builtIn.isBuiltIn = true
        try store.save(builtIn)
        let exportURL = dir.appendingPathComponent("builtin.json")
        try store.exportProfile(builtIn, to: exportURL)

        let otherDir = Self.makeTempDir()
        defer { Self.cleanup(otherDir) }
        let other = Self.makeStore(at: otherDir)
        let imported = try other.importProfile(from: exportURL)
        #expect(!imported.isBuiltIn)
    }

    // MARK: - lastError plumbing

    @Test func lastErrorIsClearedOnSuccessfulSave() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }

        let store = Self.makeStore(at: dir)
        try store.save(HearingProfile.makeDefault())
        #expect(store.lastError == nil)
    }

    @Test func lastErrorSetOnImportFailure() {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }

        let store = Self.makeStore(at: dir)
        let nonexistent = dir.appendingPathComponent("does-not-exist.json")
        #expect(throws: Error.self) {
            try store.importProfile(from: nonexistent)
        }
        #expect(store.lastError != nil)
        #expect(store.lastError?.contains("Import") == true)
    }

    // MARK: - Relocate two-phase commit

    /// `relocate(to:)` persists the new path into the store's injected
    /// defaults under this key. With ScratchDefaults the production domain
    /// can no longer be touched; the constant stays so the tests can assert
    /// the persistence actually happened.
    private static let directoryOverrideKey = "sherlockeq.profilesDirectory"

    @Test func relocateMovesFilesIntoNewDir() throws {
        let oldDir = Self.makeTempDir()
        defer { Self.cleanup(oldDir) }
        let newDir = Self.makeTempDir()
        defer { Self.cleanup(newDir) }
        let scratch = ScratchDefaults()
        defer { scratch.cleanup() }

        let store = Self.makeStore(at: oldDir, defaults: scratch.defaults)
        try store.save(HearingProfile.makeDefault(name: "A"))
        try store.save(HearingProfile.makeDefault(name: "B"))

        try store.relocate(to: newDir, moveExisting: true)

        // The new location persisted — into the scratch suite, not the
        // production domain.
        #expect(scratch.defaults.string(forKey: Self.directoryOverrideKey) == newDir.path)

        // After relocate: new dir has the two profiles, old dir is
        // empty (phase 2 deleted originals successfully).
        let inNew = try FileManager.default.contentsOfDirectory(at: newDir, includingPropertiesForKeys: nil)
        let inOld = try FileManager.default.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil)
        #expect(inNew.filter { $0.pathExtension == "json" }.count == 2)
        #expect(inOld.filter { $0.pathExtension == "json" }.isEmpty)
        #expect(store.profiles.count == 2)
    }

    @Test func relocateLeavesOldFolderAloneWhenMoveExistingFalse() throws {
        // moveExisting=false: store switches to whatever's in newDir;
        // oldDir keeps its files (user may want them as a backup).
        let oldDir = Self.makeTempDir()
        defer { Self.cleanup(oldDir) }
        let newDir = Self.makeTempDir()
        defer { Self.cleanup(newDir) }
        let scratch = ScratchDefaults()
        defer { scratch.cleanup() }

        let store = Self.makeStore(at: oldDir, defaults: scratch.defaults)
        try store.save(HearingProfile.makeDefault(name: "Stays in old"))

        try store.relocate(to: newDir, moveExisting: false)

        let inOld = try FileManager.default.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil)
        #expect(inOld.filter { $0.pathExtension == "json" }.count == 1)
        // Store's profiles array now reflects newDir (which is empty).
        #expect(store.profiles.isEmpty)
    }

    @Test func relocateToSameDirThrows() {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }

        let store = Self.makeStore(at: dir)
        #expect(throws: Error.self) {
            try store.relocate(to: dir, moveExisting: true)
        }
    }

    // MARK: - Undo action names

    @Test func saveUsesCustomActionName() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let store = Self.makeStore(at: dir)
        let undo = UndoManager()
        undo.groupsByEvent = false   // close each group synchronously for the test
        store.undoManager = undo

        // groupsByEvent == false means registerUndo requires an explicit open
        // group (in the app, SwiftUI's environment UndoManager auto-groups per
        // event); open one manually so the synchronous save can register.
        undo.beginUndoGrouping()
        try store.save(HearingProfile.makeDefault(name: "P"), actionName: "Adjust 1 kHz")
        undo.endUndoGrouping()
        #expect(undo.canUndo)
        #expect(undo.undoActionName == "Adjust 1 kHz")
    }

    @Test func saveWithoutActionNameKeepsGenericLabel() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let store = Self.makeStore(at: dir)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo

        // See saveUsesCustomActionName: open a group explicitly under
        // groupsByEvent == false so registerUndo has somewhere to land.
        undo.beginUndoGrouping()
        try store.save(HearingProfile.makeDefault(name: "Custom Mix"))
        undo.endUndoGrouping()
        #expect(undo.undoActionName == "Create Custom Mix")
    }

    // MARK: - Device links (audit CX-03)

    /// One device, one auto-activated profile: linking steals the link from
    /// any other holder — before this, auto-switch resolved duplicates by
    /// profile age, so the newer link silently never worked.
    @Test func linkDeviceStealsExistingLink() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let store = Self.makeStore(at: dir)

        var a = HearingProfile.makeDefault(name: "Older")
        a.linkedDeviceUID = "uid-headphones"
        try store.save(a)
        let b = HearingProfile.makeDefault(name: "Newer")
        try store.save(b)

        let displaced = try store.linkDevice(uid: "uid-headphones", to: b)

        #expect(displaced.map(\.id) == [a.id])
        #expect(store.profiles.first { $0.id == a.id }?.linkedDeviceUID == nil)
        #expect(store.profiles.first { $0.id == b.id }?.linkedDeviceUID == "uid-headphones")
    }

    @Test func linkDeviceNilUnlinks() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let store = Self.makeStore(at: dir)

        var p = HearingProfile.makeDefault(name: "Linked")
        p.linkedDeviceUID = "uid-x"
        try store.save(p)

        let displaced = try store.linkDevice(uid: nil, to: p)
        #expect(displaced.isEmpty)
        #expect(store.profiles.first { $0.id == p.id }?.linkedDeviceUID == nil)
    }

    /// Re-linking the profile that already holds the link displaces nothing.
    @Test func relinkSameProfileDisplacesNothing() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let store = Self.makeStore(at: dir)

        var p = HearingProfile.makeDefault(name: "Holder")
        p.linkedDeviceUID = "uid-x"
        try store.save(p)

        let displaced = try store.linkDevice(uid: "uid-x", to: p)
        #expect(displaced.isEmpty)
        #expect(store.profiles.first { $0.id == p.id }?.linkedDeviceUID == "uid-x")
    }

    /// Stealing is per-device: links to OTHER devices are untouched.
    @Test func linkDeviceLeavesOtherDevicesAlone() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let store = Self.makeStore(at: dir)

        var a = HearingProfile.makeDefault(name: "Speakers")
        a.linkedDeviceUID = "uid-speakers"
        try store.save(a)
        var b = HearingProfile.makeDefault(name: "Headphones")
        b.linkedDeviceUID = "uid-headphones"
        try store.save(b)
        let c = HearingProfile.makeDefault(name: "Contender")
        try store.save(c)

        let displaced = try store.linkDevice(uid: "uid-headphones", to: c)

        #expect(displaced.map(\.id) == [b.id])
        #expect(store.profiles.first { $0.id == a.id }?.linkedDeviceUID == "uid-speakers")
        #expect(store.profiles.first { $0.id == c.id }?.linkedDeviceUID == "uid-headphones")
    }

    // MARK: - Debounced writes (audit CX-02)

    /// save() publishes to memory immediately but defers the disk write —
    /// the file appears at the flush, not per call.
    @Test func saveDefersDiskWriteUntilFlush() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }

        let store = Self.makeStore(at: dir)
        let p = HearingProfile.makeDefault(name: "Deferred")
        try store.save(p)

        let url = dir.appendingPathComponent("\(p.id.uuidString).json")
        #expect(store.profiles.count == 1, "memory updates immediately")
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "disk write must be deferred past save()")

        store.flushPendingWrites()
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// The trailing debounce lands the write on its own — no explicit flush.
    @Test func debounceLandsWriteWithoutExplicitFlush() async throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }

        let store = Self.makeStore(at: dir)
        let p = HearingProfile.makeDefault(name: "Timer path")
        try store.save(p)

        // Debounce is 0.3 s; sleeping suspends the main actor so the
        // main-queue work item can run.
        try await Task.sleep(for: .milliseconds(700))
        let url = dir.appendingPathComponent("\(p.id.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: url.path),
                "trailing debounce should have written without a flush")
    }

    /// A burst of saves costs one write carrying the LAST snapshot.
    @Test func burstOfSavesLandsLastSnapshot() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }

        let store = Self.makeStore(at: dir)
        var p = HearingProfile.makeDefault(name: "v0")
        try store.save(p)
        for i in 1...5 {
            p.name = "v\(i)"
            try store.save(p)
        }
        store.flushPendingWrites()

        let url = dir.appendingPathComponent("\(p.id.uuidString).json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let onDisk = try decoder.decode(HearingProfile.self,
                                        from: Data(contentsOf: url))
        #expect(onDisk.name == "v5")
    }

    /// delete() cancels its profile's pending write — the debounce firing
    /// later must not resurrect the file from memory.
    @Test func deleteCancelsPendingWrite() async throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }

        let store = Self.makeStore(at: dir)
        let p = HearingProfile.makeDefault(name: "Doomed")
        try store.save(p)               // pending, not yet on disk
        try store.delete(p)             // must cancel the pending snapshot

        try await Task.sleep(for: .milliseconds(700))
        let url = dir.appendingPathComponent("\(p.id.uuidString).json")
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "debounce resurrected a deleted profile")
        #expect(store.profiles.isEmpty)
    }
}
