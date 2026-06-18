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

    private static func makeStore(at url: URL) -> ProfileStore {
        ProfileStore(directory: url)
    }

    // MARK: - Save / load round-trip

    @Test func saveThenLoadRoundTrip() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }

        let store = Self.makeStore(at: dir)
        let original = HearingProfile.makeDefault(name: "Round-trip")
        try store.save(original)

        // Fresh store reading the same dir sees the saved file.
        let fresh = Self.makeStore(at: dir)
        let loaded = fresh.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == original.id)
        #expect(loaded[0].name == "Round-trip")
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
        #expect(store.profiles.count == 1)

        try store.delete(p)
        #expect(store.profiles.isEmpty)

        // Confirm the disk is empty too.
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(urls.filter { $0.pathExtension == "json" }.isEmpty)
    }

    // MARK: - Factory presets

    /// The version-gate key lives in shared UserDefaults; reset it per test so
    /// each starts "pre-migration" and the gated reconcile actually runs.
    private static let factoryVersionKey = "sherlockeq.factoryPresetsVersion"

    @Test func reconcileInstallsFourFactoryPresetsInOrder() {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        UserDefaults.standard.set(0, forKey: Self.factoryVersionKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.factoryVersionKey) }

        let store = Self.makeStore(at: dir)
        store.reconcileFactoryPresets()
        #expect(store.profiles.map(\.name) == ["Voice Clarity", "Music Balanced", "Gentle Listening", "Presence Boost"])
        #expect(store.profiles.allSatisfy { $0.isBuiltIn })
        #expect(store.profiles.allSatisfy { $0.eqMode == .advanced })
        #expect(store.profiles.allSatisfy { $0.leftEar.bands.count == 10 })
    }

    @Test func reconcileRemovesLegacyBuiltIns() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        UserDefaults.standard.set(0, forKey: Self.factoryVersionKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.factoryVersionKey) }

        let store = Self.makeStore(at: dir)
        try store.save(.makeDefault(name: "Default", isBuiltIn: true)) // legacy random-id built-in
        store.reconcileFactoryPresets()
        #expect(!store.profiles.contains { $0.name == "Default" })
        #expect(store.profiles.count == 4)
    }

    @Test func reconcileDoesNotReAddDeletedPresetAtSameVersion() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }
        UserDefaults.standard.set(0, forKey: Self.factoryVersionKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.factoryVersionKey) }

        let store = Self.makeStore(at: dir)
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
        UserDefaults.standard.set(0, forKey: Self.factoryVersionKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.factoryVersionKey) }

        let store = Self.makeStore(at: dir)
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
        UserDefaults.standard.set(0, forKey: Self.factoryVersionKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.factoryVersionKey) }

        let store = Self.makeStore(at: dir)
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

    @Test func relocateMovesFilesIntoNewDir() throws {
        let oldDir = Self.makeTempDir()
        defer { Self.cleanup(oldDir) }
        let newDir = Self.makeTempDir()
        defer { Self.cleanup(newDir) }

        let store = Self.makeStore(at: oldDir)
        try store.save(HearingProfile.makeDefault(name: "A"))
        try store.save(HearingProfile.makeDefault(name: "B"))

        try store.relocate(to: newDir, moveExisting: true)

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

        let store = Self.makeStore(at: oldDir)
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

        try store.save(HearingProfile.makeDefault(name: "P"), actionName: "Adjust 1 kHz")
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

        try store.save(HearingProfile.makeDefault(name: "Custom Mix"))
        #expect(undo.undoActionName == "Create Custom Mix")
    }
}
