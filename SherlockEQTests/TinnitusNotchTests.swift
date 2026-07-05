//
//  TinnitusNotchTests.swift
//  SherlockEQTests
//
//  Locks in the tinnitus-notch DSP contract after the fix from a pure RBJ
//  `.notch` (gain-independent null, `1/Q` width) to a finite parametric cut:
//  Depth is honoured at center, Narrow really is narrower than Wide, and the
//  strength presets round-trip. `asEQBand()` is the single source of truth for
//  both the audio path and every curve renderer, so these invariants protect
//  what the user both sees and hears.
//

import Testing
import Foundation
@testable import SherlockEQ

struct TinnitusNotchTests {

    private static let SR: Double = 48_000
    private static let center: Double = 4_000

    private func notch(_ enabled: Bool = true, hz: Double = center, depth: Double = -6, width: NotchWidth = .medium) -> TinnitusNotch {
        TinnitusNotch(enabled: enabled, frequencyHz: hz, depthdB: depth, qWidth: width)
    }

    // MARK: - Band synthesis

    @Test func disabledNotchProducesNoBand() {
        #expect(notch(false).asEQBand() == nil)
    }

    @Test func enabledNotchIsParametricCutWithDirectQ() {
        let band = notch(depth: -8, width: .narrow).asEQBand()
        #expect(band?.filterType == .parametric)          // NOT a pure .notch
        #expect(band?.gaindB == -8)                        // depth flows through as gain
        #expect(band?.bandwidth == NotchWidth.narrow.qValue) // Q passed directly, not 1/Q
        #expect(band?.frequencyHz == Self.center)
    }

    // MARK: - Depth is real (the core regression)

    @Test func depthIsHonouredAtCenter() {
        let band = notch(depth: -6, width: .medium).asEQBand()!
        let mag = BiquadResponse.magnitudeDB(at: Self.center, band: band, sampleRate: Self.SR)
        // A parametric peaking cut hits exactly its gain at center — not the
        // infinite null the old pure-notch produced regardless of depth.
        #expect(abs(mag - (-6)) < 0.5)
    }

    @Test func deeperDepthCutsMore() {
        let shallow = BiquadResponse.magnitudeDB(at: Self.center, band: notch(depth: -3).asEQBand()!, sampleRate: Self.SR)
        let deep    = BiquadResponse.magnitudeDB(at: Self.center, band: notch(depth: -12).asEQBand()!, sampleRate: Self.SR)
        // Under the old gain-independent notch these were indistinguishable.
        #expect(deep < shallow - 5)
    }

    // MARK: - Width direction is correct

    @Test func narrowAffectsLessOffCenterThanWide() {
        // A quarter-octave above center: the narrower (higher-Q) filter should
        // attenuate LESS there than the wide one.
        let offset = Self.center * pow(2.0, 0.25)
        let narrow = BiquadResponse.magnitudeDB(at: offset, band: notch(width: .narrow).asEQBand()!, sampleRate: Self.SR)
        let wide   = BiquadResponse.magnitudeDB(at: offset, band: notch(width: .wide).asEQBand()!, sampleRate: Self.SR)
        #expect(narrow > wide)   // closer to 0 dB = less affected
    }

    @Test func octaveBandwidthOrdersNarrowToWide() {
        #expect(NotchWidth.narrow.approxOctaves < NotchWidth.medium.approxOctaves)
        #expect(NotchWidth.medium.approxOctaves < NotchWidth.wide.approxOctaves)
    }

    // MARK: - Presets

    @Test func applyPresetSetsWidthAndDepthOnly() {
        var n = notch(hz: 7_000, depth: -6, width: .medium)
        n.apply(.strong)
        #expect(n.qWidth == .wide)
        #expect(n.depthdB == -12)
        #expect(n.frequencyHz == 7_000)   // pitch untouched
        #expect(n.enabled == true)        // on/off untouched
    }

    @Test func presetDetectionRoundTrips() {
        for preset in NotchPreset.allCases {
            var n = notch()
            n.apply(preset)
            #expect(n.preset == preset)
        }
    }

    @Test func customCombinationReadsAsNil() {
        #expect(notch(depth: -9, width: .narrow).preset == nil)
    }

    @Test func defaultDisabledReadsAsBalanced() {
        // Existing default (medium / -6) maps to Balanced, so the control shows
        // a sensible conservative preset rather than "Custom".
        #expect(TinnitusNotch.disabled.preset == .balanced)
    }
}
