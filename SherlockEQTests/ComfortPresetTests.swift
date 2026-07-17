//
//  ComfortPresetTests.swift
//  SherlockEQTests
//
//  `ComfortPreset.matching` decides which preset chip highlights on the
//  Adaptive Comfort screen — it shipped with zero coverage (audit TD-03).
//

import Testing
@testable import SherlockEQ

@MainActor
struct ComfortPresetTests {

    /// Apply a preset to both ears of a fresh settings value, the way the
    /// screen's preset buttons do.
    private static func applied(_ preset: ComfortPreset) -> DynamicProcessingSettings {
        var d = DynamicProcessingSettings()
        for kind in DynamicFeatureKind.allCases {
            d.setSettings(preset.settings(for: kind), for: kind, ear: .left)
            d.setSettings(preset.settings(for: kind), for: kind, ear: .right)
        }
        return d
    }

    @Test func eachPresetRoundTripsThroughMatching() {
        for preset in ComfortPreset.allCases {
            #expect(ComfortPreset.matching(Self.applied(preset)) == preset)
        }
    }

    @Test func freshSettingsMatchOff() {
        // Everything defaults to disabled, which is exactly the Off pattern.
        #expect(ComfortPreset.matching(DynamicProcessingSettings()) == .off)
    }

    @Test func customMixesMatchNoPreset() {
        // Every enabled-pattern that isn't exactly off / dialogue / gentle.
        let custom: [[DynamicFeatureKind]] = [
            [.harshnessControl],
            [.sibilanceTamer],
            [.speechPresence, .harshnessControl],
            [.speechPresence, .sibilanceTamer],
            [.speechPresence, .harshnessControl, .sibilanceTamer],
        ]
        for kinds in custom {
            var d = DynamicProcessingSettings()
            for kind in kinds {
                d.setSettings(.init(enabled: true), for: kind, ear: .left)
                d.setSettings(.init(enabled: true), for: kind, ear: .right)
            }
            #expect(ComfortPreset.matching(d) == nil,
                    "\(kinds.map(\.rawValue)) should read as a custom mix")
        }
    }

    /// Only the enabled flags are compared — nudging Amount or sensitivity
    /// must keep the preset highlighted (the documented contract on
    /// `matching`).
    @Test func sliderNudgesKeepThePresetMatched() {
        var d = Self.applied(.dialogue)
        var s = d.settings(for: .speechPresence, ear: .left)
        s.strength = 0.93
        s.sensitivity = 0.11
        d.setSettings(s, for: .speechPresence, ear: .left)
        #expect(ComfortPreset.matching(d) == .dialogue)
    }

    /// A feature counts as on when EITHER ear runs it, so separate-ear users
    /// keep the highlight too.
    @Test func singleEarEnableCountsAsOn() {
        var d = DynamicProcessingSettings()
        d.setSettings(.init(enabled: true), for: .speechPresence, ear: .left)
        #expect(ComfortPreset.matching(d) == .dialogue)
    }
}
