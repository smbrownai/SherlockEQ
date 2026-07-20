//
//  ToneMacroTests.swift
//  SherlockEQTests
//
//  The popover's quick adjustments are deltas over the 12 graphic bands, not
//  filters. These pin the properties that would rot silently: that every
//  weight lands on a real graphic center, that the shapes cover the regions
//  they claim, that deltas accumulate and reverse cleanly, and that clamping
//  is reported rather than swallowed.
//

import Testing
import Foundation
@testable import SherlockEQ

@MainActor
struct ToneMacroTests {

    /// Build a flat 12-band graphic curve.
    private func flatGraphic(_ gain: Double = 0) -> [EQBand] {
        EQMode.graphicCenters.map {
            EQBand(frequencyHz: $0, gaindB: gain, bandwidth: ToneMacro.graphicBandwidth,
                   filterType: .parametric, enabled: true)
        }
    }

    private func gain(_ freq: Double, _ bands: [EQBand]) -> Double {
        EQBandLookup.gain(at: freq, filterType: .parametric, in: bands)
    }

    // MARK: - The weights must address real bands

    /// A weight keyed to a frequency that isn't a graphic center does nothing
    /// at all — silently. This is the single most likely way to break these
    /// curves (typing 3150 for 3000, say) and the least likely to be noticed.
    @Test func everyWeightKeyIsAGraphicCenter() {
        let centers = Set(EQMode.graphicCenters)
        for macro in ToneMacro.allCases {
            for key in macro.weights.keys {
                #expect(centers.contains(key),
                        "\(macro.rawValue) weights \(key) Hz, which is not a graphic center")
            }
        }
    }

    /// Every macro must actually reach bands; a macro whose centers came back
    /// empty would render buttons that do nothing.
    @Test func everyMacroTouchesBands() {
        for macro in ToneMacro.allCases {
            #expect(!macro.centers.isEmpty, "\(macro.rawValue) touches no bands")
        }
    }

    // MARK: - Shapes cover what they claim

    @Test func bassCoversLowsAndTapersOut() {
        var bands = flatGraphic()
        ToneMacro.apply(.bass, direction: .up, to: &bands)
        // Full strength at the bottom, tapering through 500 Hz.
        #expect(gain(31.5, bands) == 1.0)
        #expect(gain(63, bands) == 1.0)
        #expect(gain(250, bands) > 0 && gain(250, bands) < gain(125, bands))
        #expect(gain(500, bands) > 0 && gain(500, bands) < gain(250, bands))
        // Untouched above the taper.
        #expect(gain(1000, bands) == 0)
        #expect(gain(8000, bands) == 0)
    }

    @Test func midIsBroadAndCenteredAtOneKilohertz() {
        var bands = flatGraphic()
        ToneMacro.apply(.mid, direction: .up, to: &bands)
        #expect(gain(1000, bands) == 1.0)
        // Symmetric shoulders.
        #expect(gain(500, bands) == gain(2000, bands))
        #expect(gain(250, bands) == gain(3000, bands))
        // Doesn't leak into the extremes.
        #expect(gain(31.5, bands) == 0)
        #expect(gain(16000, bands) == 0)
    }

    @Test func trebleCoversHighsAndTapersOut() {
        var bands = flatGraphic()
        ToneMacro.apply(.treble, direction: .up, to: &bands)
        #expect(gain(4000, bands) > 0)
        #expect(gain(8000, bands) == 1.0)
        #expect(gain(16000, bands) == 1.0)
        #expect(gain(2000, bands) > 0 && gain(2000, bands) < gain(3000, bands))
        #expect(gain(250, bands) == 0)
    }

    // MARK: - Delta semantics

    /// The core promise: nudges add to what's there. They never re-fit a
    /// shape, so a user's existing curve survives underneath.
    @Test func nudgesAddToExistingGains() {
        var bands = flatGraphic()
        // Plant an unrelated user edit inside the bass region.
        EQBandLookup.setGain(-4, at: 63, bandwidth: ToneMacro.graphicBandwidth,
                             filterType: .parametric, in: &bands)
        ToneMacro.apply(.bass, direction: .up, to: &bands)
        #expect(gain(63, bands) == -3, "should be -4 + 1, not re-fitted to a shelf")
    }

    @Test func nudgesAccumulate() {
        var bands = flatGraphic()
        for _ in 0..<3 { ToneMacro.apply(.bass, direction: .up, to: &bands) }
        #expect(gain(31.5, bands) == 3.0)
    }

    /// **This test is the undo button.**
    ///
    /// The popover ships no undo control because the opposite button already
    /// is one. That's only true if every pair is exactly symmetric, so this
    /// pins it for all three macros, over repeated presses, on a curve that
    /// isn't flat. If this ever fails, the popover has silently lost its
    /// ability to take back a nudge.
    @Test func oppositeNudgesCancel() {
        for macro in ToneMacro.allCases {
            var bands = flatGraphic(2)
            // An uneven starting curve — symmetry must not depend on flatness.
            EQBandLookup.setGain(-5.5, at: 500, bandwidth: ToneMacro.graphicBandwidth,
                                 filterType: .parametric, in: &bands)
            let before = EQMode.graphicCenters.map { gain($0, bands) }

            for _ in 0..<3 { ToneMacro.apply(macro, direction: .up, to: &bands) }
            for _ in 0..<3 { ToneMacro.apply(macro, direction: .down, to: &bands) }

            for (center, expected) in zip(EQMode.graphicCenters, before) {
                #expect(abs(gain(center, bands) - expected) < 0.0001,
                        "\(macro.rawValue) is not reversible at \(center) Hz")
            }
        }
    }

    /// The one place the opposite button *isn't* a perfect undo: a nudge that
    /// clamped at the rail lost information, so reversing it lands lower than
    /// it started. Pinned deliberately — this is why a clamped nudge says so
    /// in the UI instead of passing silently.
    @Test func reversingAClampedNudgeDoesNotReturnToStart() {
        var bands = flatGraphic(11.8)
        ToneMacro.apply(.bass, direction: .up, to: &bands)     // 31.5 clamps 11.8 → 12
        ToneMacro.apply(.bass, direction: .down, to: &bands)   // 12 − 1 = 11
        #expect(gain(31.5, bands) == 11, "clamped movement is not recoverable by reversing")
        // A band that never hit the rail still round-trips exactly.
        #expect(abs(gain(500, bands) - 11.8) < 0.0001)
    }

    @Test func downNudgeLowersGains() {
        var bands = flatGraphic()
        ToneMacro.apply(.mid, direction: .down, to: &bands)
        #expect(gain(1000, bands) == -1.0)
    }

    // MARK: - Clamping is reported, not swallowed

    /// A macro must never push past what the Graphic sliders can show, or the
    /// "open the EQ to see what happened" promise breaks.
    @Test func clampsToGraphicRange() {
        var bands = flatGraphic(11.5)
        let outcome = ToneMacro.apply(.bass, direction: .up, to: &bands)
        #expect(gain(31.5, bands) == 12, "must stop at the graphic rail")
        #expect(outcome.clamped > 0, "partial movement must be reported")
        #expect(!outcome.isNoOp, "bands below the rail still moved")
    }

    /// Everything already railed → nothing moves, and the UI is told so it can
    /// say "already at its limit" instead of pretending it did something.
    @Test func fullyRailedRegionIsANoOp() {
        var bands = flatGraphic(12)
        let outcome = ToneMacro.apply(.bass, direction: .up, to: &bands)
        #expect(outcome.isNoOp)
        #expect(outcome.moved == 0)
    }

    @Test func unclampedNudgeReportsNoClamping() {
        var bands = flatGraphic()
        let outcome = ToneMacro.apply(.mid, direction: .up, to: &bands)
        #expect(outcome.clamped == 0)
        #expect(outcome.moved == ToneMacro.mid.centers.count)
    }

    // MARK: - Naming

    /// Each of the six buttons needs its own phrase for VoiceOver — two rows
    /// both showing "Softer" are only distinguishable by their accessibility
    /// label.
    @Test func actionNamesAreUnique() {
        var names: Set<String> = []
        for macro in ToneMacro.allCases {
            for direction in [ToneMacro.Direction.up, .down] {
                names.insert(macro.actionName(direction))
            }
        }
        #expect(names.count == 6)
    }

    // MARK: - Separation from ToneTrim

    /// Macros write plain graphic parametrics. If one ever emitted a shelf it
    /// would land in `ToneTrim`'s slots and start showing up as a "Tone trim"
    /// readout — two editing models tangled together again.
    @Test func macrosOnlyWriteGraphicParametrics() {
        var bands: [EQBand] = []
        for macro in ToneMacro.allCases {
            ToneMacro.apply(macro, direction: .up, to: &bands)
        }
        #expect(bands.allSatisfy { $0.filterType == .parametric })
        #expect(bands.allSatisfy { EQMode.graphicCenters.contains($0.frequencyHz) })
        #expect(EQMode.advanced.hiddenBands(in: bands).isEmpty,
                "a macro must never produce an 'other filter'")
        #expect(ToneTrim.offGridValues(in: bands).isEmpty,
                "a macro must never register as a tone trim")
    }
}
