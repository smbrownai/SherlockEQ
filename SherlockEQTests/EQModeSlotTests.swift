//
//  EQModeSlotTests.swift
//  SherlockEQTests
//
//  The Graphic (Advanced) surface's 12-band audiometric grid and its
//  slot-ownership contract (phase3-make-correction-land.md §2). Two
//  invariants matter:
//    1. The grid includes 3 kHz and 6 kHz — audiogram frequencies that
//       previously had no graphic slider — and `ownedSlots` follows the
//       same canonical list, so bands there are editable, not "hidden".
//    2. The factory-preset builder stays frozen on the v1 10-center list
//       (its gains arrays are positional; the §3 migration also compares
//       stored presets against exact v1 output to detect user edits).
//

import Testing
import Foundation
@testable import SherlockEQ

struct EQModeSlotTests {

    private func band(
        hz: Double,
        type: EQFilterType = .parametric,
        gainDB: Double = 3
    ) -> EQBand {
        EQBand(frequencyHz: hz, gaindB: gainDB, bandwidth: 1.0, filterType: type, enabled: true)
    }

    // MARK: - Canonical grid

    @Test func graphicGridIsTheTwelveBandAudiometricSet() {
        #expect(EQMode.graphicCenters == [
            31.5, 63, 125, 250, 500, 1000, 2000, 3000, 4000, 6000, 8000, 16000
        ])
    }

    // MARK: - Slot ownership (drives the hidden-bands accounting)

    @Test func advancedOwnsEveryGraphicCenter() {
        let bands = EQMode.graphicCenters.map { band(hz: $0) }
        #expect(EQMode.advanced.hiddenBands(in: bands).isEmpty)
    }

    @Test func threeAndSixKilohertzAreEditableInGraphic() {
        // The point of the grid change: a Parametric-authored 3k/6k band
        // surfaces on the graphic sliders instead of hiding.
        let bands = [band(hz: 3000), band(hz: 6000)]
        #expect(EQMode.advanced.hiddenBands(in: bands).isEmpty)
    }

    @Test func offGridBandStaysHiddenInGraphic() {
        let hidden = EQMode.advanced.hiddenBands(in: [band(hz: 2500)])
        #expect(hidden.map(\.frequencyHz) == [2500])
    }

    @Test func slotOwnershipIsTypeAware() {
        // A notch at 3 kHz is not the graphic slider's parametric slot.
        let hidden = EQMode.advanced.hiddenBands(in: [band(hz: 3000, type: .notch)])
        #expect(hidden.count == 1)
    }

    @Test func expertHidesNothing() {
        let bands = [band(hz: 2500), band(hz: 3000, type: .notch)]
        #expect(EQMode.expert.hiddenBands(in: bands).isEmpty)
    }

    // MARK: - Factory presets live on the graphic grid

    @Test func factoryPresetsAreVoicedOnTheGraphicGrid() {
        // §3 re-voicing: factory presets wrap `PresetCurve`s, which emit one
        // band per graphic center — surface and presets share one grid.
        for preset in HearingProfile.factoryProfiles {
            #expect(preset.leftEar.bands.map(\.frequencyHz) == EQMode.graphicCenters)
            #expect(preset.rightEar.bands.map(\.frequencyHz) == EQMode.graphicCenters)
        }
    }

    @Test func factoryPresetBandsAreAllOwnedByGraphic() {
        for preset in HearingProfile.factoryProfiles {
            #expect(EQMode.advanced.hiddenBands(in: preset.leftEar.bands).isEmpty)
        }
    }

    @Test func factoryPresetsMatchTheirSharedCurves() {
        // The factory profiles and the Graphic selector consume ONE curve
        // table — a factory card must read as its curve, not as "Custom".
        let pairs: [(HearingProfile, PresetCurve)] = [
            (HearingProfile.factoryVoiceClarity(), .clearerVoices),
            (HearingProfile.factoryMusicBalanced(), .musicBalance),
            (HearingProfile.factoryGentleListening(), .gentleListening),
            (HearingProfile.factoryReduceBoom(), .reduceBoom),
        ]
        for (profile, curve) in pairs {
            let gains = profile.leftEar.bands.map(\.gaindB)
            let matched = PresetCurve.matching(
                leftGains: gains, rightGains: gains, trimDB: profile.globalTrimDB)
            #expect(matched == curve)
        }
    }
}
