//
//  RetiredGraphicBandTests.swift
//  SherlockEQTests
//
//  The Graphic surface returned to the 10 ISO octaves, retiring 3 kHz and
//  6 kHz. Profiles the factory reconcile leaves alone — user profiles, and any
//  preset with an edit — keep bands at those frequencies, which the sliders can
//  no longer reach. These pin that the one-time fold moves them onto the
//  surviving grid without changing how the profile sounds.
//

import Testing
import Foundation
@testable import SherlockEQ

@MainActor
struct RetiredGraphicBandTests {

    private static func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SherlockEQTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let migrationKey = "sherlockeq.retiredGraphicBandsMigrated"

    private func scratch() -> UserDefaults {
        UserDefaults(suiteName: "SherlockEQTests.\(UUID().uuidString)")!
    }

    /// A profile on the old 12-band grid.
    private func v2Profile(_ name: String, gains: [Double]) -> HearingProfile {
        let centers: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 3000, 4000, 6000, 8000, 16000]
        let bands = zip(centers, gains).map {
            EQBand(frequencyHz: $0, gaindB: $1, bandwidth: 1.0,
                   filterType: .parametric, enabled: true)
        }
        var p = HearingProfile.makeDefault(name: name)
        p.leftEar.bands = bands
        p.rightEar.bands = bands
        return p
    }

    private func response(_ bands: [EQBand], at hz: Double) -> Double {
        BiquadResponse.compositeMagnitudeDB(at: hz, bands: bands.filter(\.enabled))
    }

    // MARK: - The fold

    /// The point of the migration: nothing is left at a frequency the Graphic
    /// screen can't edit, so no "Other filters" warning about the app's own
    /// bands.
    @Test func retiredBandsAreRemoved() throws {
        let dir = Self.makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = scratch(); defer { defaults.removePersistentDomain(forName: defaults.description) }
        let store = ProfileStore(directory: dir, defaults: defaults)
        try store.save(v2Profile("Edited", gains: [0, 0, 0, 0, 0, 0, 2, 4, 3, -2, 1, 0]))

        store.migrateRetiredGraphicBandsIfNeeded()

        let after = try #require(store.profiles.first)
        let retired = after.leftEar.bands.filter { $0.frequencyHz == 3000 || $0.frequencyHz == 6000 }
        #expect(retired.isEmpty)
        #expect(EQMode.advanced.hiddenBands(in: after.leftEar.bands).isEmpty,
                "nothing may be left off-grid")
    }

    /// And the profile still sounds like itself. The fold adds the retired
    /// bands' fitted contribution to the surviving sliders, so the composite
    /// response is preserved up to the fit error.
    @Test func responseIsPreservedAcrossTheFold() throws {
        let dir = Self.makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = scratch(); defer { defaults.removePersistentDomain(forName: defaults.description) }
        let store = ProfileStore(directory: dir, defaults: defaults)
        let original = v2Profile("Shaped", gains: [0, 0, 0, 0, 0, 0, 2, 4, 3, -2, 1, 0])
        try store.save(original)

        store.migrateRetiredGraphicBandsIfNeeded()
        let after = try #require(store.profiles.first)

        var worst = 0.0
        for i in 0...120 {
            let hz = 20 * pow(1000, Double(i) / 120)
            worst = max(worst, abs(response(after.leftEar.bands, at: hz)
                                   - response(original.leftEar.bands, at: hz)))
        }
        #expect(worst < 2.0, "fold changed the sound by \(worst) dB")
    }

    /// Both ears, not just the one the sliders happen to show.
    @Test func bothEarsAreFolded() throws {
        let dir = Self.makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = scratch(); defer { defaults.removePersistentDomain(forName: defaults.description) }
        let store = ProfileStore(directory: dir, defaults: defaults)
        try store.save(v2Profile("Both", gains: [0, 0, 0, 0, 0, 0, 0, 5, 0, 5, 0, 0]))

        store.migrateRetiredGraphicBandsIfNeeded()
        let after = try #require(store.profiles.first)
        #expect(!after.leftEar.bands.contains { $0.frequencyHz == 3000 })
        #expect(!after.rightEar.bands.contains { $0.frequencyHz == 3000 })
        #expect(!after.rightEar.bands.contains { $0.frequencyHz == 6000 })
    }

    // MARK: - Restraint

    /// A profile with nothing at 3k/6k must not be touched at all — no
    /// modifiedAt bump, nothing newly marked as edited.
    @Test func profilesWithoutRetiredBandsAreUntouched() throws {
        let dir = Self.makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = scratch(); defer { defaults.removePersistentDomain(forName: defaults.description) }
        let store = ProfileStore(directory: dir, defaults: defaults)

        var p = HearingProfile.makeDefault(name: "Clean")
        p.leftEar.bands = [EQBand(frequencyHz: 1000, gaindB: 3, bandwidth: 1.0,
                                  filterType: .parametric, enabled: true)]
        try store.save(p)
        let before = try #require(store.profiles.first).modifiedAt

        store.migrateRetiredGraphicBandsIfNeeded()
        #expect(try #require(store.profiles.first).modifiedAt == before)
    }

    /// A 3 kHz *notch* is not a graphic slot — the notch stage owns it, and
    /// folding it into a bell would silently change a tinnitus setting.
    @Test func nonParametricBandsAtRetiredCentersSurvive() throws {
        let dir = Self.makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = scratch(); defer { defaults.removePersistentDomain(forName: defaults.description) }
        let store = ProfileStore(directory: dir, defaults: defaults)

        var p = HearingProfile.makeDefault(name: "Notched")
        p.leftEar.bands = [EQBand(frequencyHz: 3000, gaindB: -12, bandwidth: 0.3,
                                  filterType: .notch, enabled: true)]
        p.rightEar.bands = p.leftEar.bands
        try store.save(p)

        store.migrateRetiredGraphicBandsIfNeeded()
        let after = try #require(store.profiles.first)
        #expect(after.leftEar.bands.contains { $0.frequencyHz == 3000 && $0.filterType == .notch })
    }

    /// Runs once. A band the user deliberately authors at 3 kHz in Parametric
    /// afterwards must survive — it's their choice, and the Graphic screen
    /// already reports it honestly as an other filter.
    @Test func migrationDoesNotRunTwice() throws {
        let dir = Self.makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = scratch(); defer { defaults.removePersistentDomain(forName: defaults.description) }
        let store = ProfileStore(directory: dir, defaults: defaults)
        try store.save(v2Profile("Later edit", gains: [0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0]))
        store.migrateRetiredGraphicBandsIfNeeded()

        var again = try #require(store.profiles.first)
        again.leftEar.bands.append(EQBand(frequencyHz: 3000, gaindB: 6, bandwidth: 1.0,
                                          filterType: .parametric, enabled: true))
        try store.save(again)

        store.migrateRetiredGraphicBandsIfNeeded()
        #expect(try #require(store.profiles.first).leftEar.bands
                    .contains { $0.frequencyHz == 3000 },
                "a second pass must not eat a band authored after the migration")
        #expect(defaults.bool(forKey: Self.migrationKey))
    }

    // MARK: - Factory reconcile

    /// Anyone pristine on the v2 grid must be upgraded, not treated as edited.
    /// Missing this would leave untouched presets carrying 3k/6k bands the
    /// sliders can't reach — the exact state the fold exists to prevent, on
    /// profiles the user never touched.
    @Test func pristineV2PresetsAreRecognised() {
        for preset in ProfileStore.FrozenFactoryV2.profiles {
            #expect(ProfileStore.FrozenFactoryV2.isUneditedV2(preset),
                    "\(preset.name) should match its own frozen definition")
        }
    }

    @Test func editedV2PresetIsNotTreatedAsPristine() throws {
        var edited = try #require(ProfileStore.FrozenFactoryV2.profiles.first)
        EQBandLookup.setGain(7, at: 1000, bandwidth: 1.0,
                             filterType: .parametric, in: &edited.leftEar.bands)
        #expect(!ProfileStore.FrozenFactoryV2.isUneditedV2(edited))
    }

    /// The shipped curves must live on the new grid, or every freshly
    /// installed preset would immediately need the fold.
    @Test func shippedCurvesAreOnTheNewGrid() {
        for curve in PresetCurve.allCases {
            #expect(curve.gains.count == EQMode.graphicCenters.count,
                    "\(curve.rawValue) has \(curve.gains.count) gains for \(EQMode.graphicCenters.count) centers")
        }
    }
}
