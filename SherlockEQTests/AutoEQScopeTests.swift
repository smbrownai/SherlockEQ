//
//  AutoEQScopeTests.swift
//  SherlockEQTests
//
//  The headphone-correction on/off switch moved from a single app-wide
//  preference onto each profile. Two things must hold: the flag survives a
//  JSON round-trip and defaults to "on" for profiles written before it
//  existed, and the one-time migration carries a deliberately-bypassed global
//  onto the profiles rather than silently re-enabling their corrections.
//

import Testing
import Foundation
@testable import SherlockEQ

@MainActor
struct AutoEQScopeTests {

    // MARK: - Harness (mirrors ProfileStoreTests: temp dir + scratch defaults)

    private static func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SherlockEQTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    private static let legacyGlobalKey = "sherlockeq.autoEQEnabled"
    private static let migratedKey = "sherlockeq.autoEQScopeMigrated"

    private func withCorrection(_ name: String) -> HearingProfile {
        var p = HearingProfile.makeDefault(name: name)
        p.autoEQName = "DT770"
        p.autoEQBands = [EQBand(frequencyHz: 100, gaindB: -3, bandwidth: 1.0,
                                filterType: .parametric, enabled: true)]
        return p
    }

    // MARK: - Persistence

    /// The flag has to ride the profile JSON, or "sticks with the profile" is
    /// only true until relaunch.
    @Test func flagSurvivesAnEncodeDecodeRoundTrip() throws {
        var p = withCorrection("Round trip")
        p.autoEQEnabled = false
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(HearingProfile.self, from: data)
        #expect(back.autoEQEnabled == false)
    }

    /// Profiles written before this field existed were, by definition, using
    /// whatever correction they had. Decoding them as "off" would silently
    /// mute every existing user's headphone EQ.
    @Test func legacyProfileWithoutTheKeyDecodesAsOn() throws {
        let p = withCorrection("Legacy")
        var json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(p)) as! [String: Any]
        json.removeValue(forKey: "autoEQEnabled")
        let data = try JSONSerialization.data(withJSONObject: json)
        let back = try JSONDecoder().decode(HearingProfile.self, from: data)
        #expect(back.autoEQEnabled, "a profile predating the flag must default to on")
    }

    @Test func newProfilesDefaultToOn() {
        #expect(HearingProfile.makeDefault(name: "Fresh").autoEQEnabled)
    }

    // MARK: - Migration

    /// The case the migration exists for: someone deliberately switched the
    /// old global off. A default of "on" would hand their headphones back a
    /// correction they had chosen to disable.
    @Test func bypassedGlobalIsCarriedOntoProfilesWithCorrections() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let defaults = UserDefaults(suiteName: "SherlockEQTests.\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        defaults.set(false, forKey: Self.legacyGlobalKey)

        let store = ProfileStore(directory: dir, defaults: defaults)
        try store.save(withCorrection("Has correction"))
        try store.save(HearingProfile.makeDefault(name: "No correction"))

        store.migrateAutoEQScopeIfNeeded()

        let corrected = try #require(store.profiles.first { $0.name == "Has correction" })
        #expect(!corrected.autoEQEnabled, "the user's bypass must survive the move")

        // Nothing to bypass on a profile with no correction — stamping it off
        // would mark it edited for no reason.
        let bare = try #require(store.profiles.first { $0.name == "No correction" })
        #expect(bare.autoEQEnabled)

        // The global reverts to its new meaning: a Debug-only stage bypass.
        #expect(defaults.bool(forKey: Self.legacyGlobalKey))
        #expect(defaults.bool(forKey: Self.migratedKey))
    }

    /// The common case — the global was on, or never touched. Nothing should
    /// move, and no profile should be marked edited.
    @Test func enabledGlobalLeavesEveryProfileAlone() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let defaults = UserDefaults(suiteName: "SherlockEQTests.\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        defaults.set(true, forKey: Self.legacyGlobalKey)

        let store = ProfileStore(directory: dir, defaults: defaults)
        try store.save(withCorrection("Untouched"))
        let before = try #require(store.profiles.first).modifiedAt

        store.migrateAutoEQScopeIfNeeded()

        let after = try #require(store.profiles.first)
        #expect(after.autoEQEnabled)
        #expect(after.modifiedAt == before, "a no-op migration must not touch the profile")
    }

    /// Never set → never bypassed. Must be treated as "on", not as false.
    @Test func absentGlobalKeyIsANoOp() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let defaults = UserDefaults(suiteName: "SherlockEQTests.\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let store = ProfileStore(directory: dir, defaults: defaults)
        try store.save(withCorrection("Fresh install"))
        store.migrateAutoEQScopeIfNeeded()

        #expect(try #require(store.profiles.first).autoEQEnabled)
    }

    /// Runs once. A second pass must not re-stamp profiles the user has since
    /// switched back on.
    @Test func migrationDoesNotRunTwice() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let defaults = UserDefaults(suiteName: "SherlockEQTests.\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        defaults.set(false, forKey: Self.legacyGlobalKey)

        let store = ProfileStore(directory: dir, defaults: defaults)
        try store.save(withCorrection("Toggled back"))
        store.migrateAutoEQScopeIfNeeded()

        // User switches it back on after the migration.
        var back = try #require(store.profiles.first)
        back.autoEQEnabled = true
        try store.save(back)
        // …and something turns the old global off again.
        defaults.set(false, forKey: Self.legacyGlobalKey)

        store.migrateAutoEQScopeIfNeeded()
        #expect(try #require(store.profiles.first).autoEQEnabled,
                "a second migration pass must not undo the user's choice")
    }

    // MARK: - Gating

    /// Both switches must be on. These are the four corners of the AND that
    /// `applyBypassMask` and `CorrectionLayerStatus` share.
    @Test func bothSwitchesMustBeOn() {
        var on = withCorrection("On")
        var off = withCorrection("Off")
        off.autoEQEnabled = false
        on.autoEQEnabled = true

        #expect(CorrectionLayerStatus(profile: on, masterEnabled: true, autoEQEnabled: true).headphone)
        #expect(!CorrectionLayerStatus(profile: on, masterEnabled: true, autoEQEnabled: false).headphone,
                "chain-level bypass must win over a profile that wants its correction")
        #expect(!CorrectionLayerStatus(profile: off, masterEnabled: true, autoEQEnabled: true).headphone,
                "profile flag must win over an enabled chain stage")
        #expect(!CorrectionLayerStatus(profile: off, masterEnabled: false, autoEQEnabled: false).headphone)
    }

    /// Bypassing one profile's correction must leave another profile's alone —
    /// the whole point of the change.
    @Test func profilesAreIndependent() {
        var a = withCorrection("A")
        let b = withCorrection("B")
        a.autoEQEnabled = false
        #expect(!CorrectionLayerStatus(profile: a, masterEnabled: true, autoEQEnabled: true).headphone)
        #expect(CorrectionLayerStatus(profile: b, masterEnabled: true, autoEQEnabled: true).headphone)
    }
}
