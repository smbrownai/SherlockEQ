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

    // MARK: - Seeding

    @Test func seedDefaultsCreatesDefaultAndVoiceClarity() {
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }

        let store = Self.makeStore(at: dir)
        store.seedDefaultsIfEmpty()
        #expect(store.profiles.count == 2)
        #expect(store.profiles.contains { $0.name == "Default" })
        #expect(store.profiles.contains { $0.name == "Voice Clarity" })
    }

    @Test func seedDefaultsIsIdempotent() throws {
        // A second call when profiles already exist is a no-op.
        let dir = Self.makeTempDir()
        defer { Self.cleanup(dir) }

        let store = Self.makeStore(at: dir)
        store.seedDefaultsIfEmpty()
        let firstCount = store.profiles.count

        store.seedDefaultsIfEmpty()
        #expect(store.profiles.count == firstCount)
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
}
