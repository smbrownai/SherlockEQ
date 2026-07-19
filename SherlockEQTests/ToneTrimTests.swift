//
//  ToneTrimTests.swift
//  SherlockEQTests
//
//  The three-band tone layout (`sherlockeq simple-eq`, the Shortcuts intents,
//  the Analog Control Unit) is a first-class band layout the Graphic surface
//  owns. These pin the two things that would silently regress: that the tone
//  slots stay owned (so a tone trim never reappears as an "Other filters"
//  warning about the user's own setting), and that the readout reports only
//  the bands the sliders can't show.
//

import Testing
import Foundation
@testable import SherlockEQ

@MainActor
struct ToneTrimTests {

    // MARK: - Slot ownership

    /// Every tone slot must be owned by Graphic — that's the whole point of
    /// the change. `hiddenBands` returning any of them means the Graphic
    /// screen would raise its orange "other filters active" row.
    @Test func toneSlotsAreOwnedByGraphic() {
        let bands = ToneTrim.slots.map { slot in
            EQBand(frequencyHz: slot.frequencyHz, gaindB: 3,
                   bandwidth: ToneTrim.bandwidth, filterType: slot.filterType, enabled: true)
        }
        #expect(EQMode.advanced.hiddenBands(in: bands).isEmpty,
                "A tone trim must not surface as a hidden/other filter")
    }

    /// A genuinely off-layout band still counts as hidden — owning the tone
    /// slots must not accidentally own everything.
    @Test func unrelatedBandIsStillHidden() {
        let stray = EQBand(frequencyHz: 750, gaindB: 4, bandwidth: 1.0,
                           filterType: .parametric, enabled: true)
        let hidden = EQMode.advanced.hiddenBands(in: [stray])
        #expect(hidden.count == 1)
        #expect(hidden.first?.frequencyHz == 750)
    }

    /// Parametric owns everything, tone slots included — unchanged.
    @Test func parametricHidesNothing() {
        let bands = ToneTrim.slots.map { slot in
            EQBand(frequencyHz: slot.frequencyHz, gaindB: -2,
                   bandwidth: ToneTrim.bandwidth, filterType: slot.filterType, enabled: true)
        }
        #expect(EQMode.expert.hiddenBands(in: bands).isEmpty)
    }

    // MARK: - Mid is the 1 kHz slider

    /// The mid slot is `(1000, .parametric)`, which is also a graphic center —
    /// the same stored band reached two ways. `offGrid` must therefore exclude
    /// it, or the readout would print a value the slider already shows.
    @Test func midIsAGraphicCenterAndExcludedFromOffGrid() {
        let mid = try! #require(ToneTrim.slots.first { $0.key == "mid" })
        #expect(mid.filterType == .parametric)
        #expect(EQMode.graphicCenters.contains(mid.frequencyHz),
                "mid should coincide with a graphic slider center")
        #expect(!ToneTrim.offGrid.contains(mid),
                "mid is the 1 kHz slider, so it must not be reported separately")
    }

    /// The two shelves are genuinely invisible to the sliders, so they are
    /// exactly what `offGrid` reports.
    @Test func offGridIsTheTwoShelves() {
        #expect(ToneTrim.offGrid.map(\.key) == ["bass", "treble"])
    }

    // MARK: - Readout values

    @Test func offGridValuesReportsSetShelvesOnly() {
        var bands: [EQBand] = []
        EQBandLookup.setGain(3, at: 250, bandwidth: ToneTrim.bandwidth,
                             filterType: .lowShelf, in: &bands)
        // Mid set too — must NOT appear, it's the 1 kHz slider's job.
        EQBandLookup.setGain(2, at: 1000, bandwidth: ToneTrim.bandwidth,
                             filterType: .parametric, in: &bands)

        let values = ToneTrim.offGridValues(in: bands)
        #expect(values.count == 1)
        #expect(values.first?.slot.key == "bass")
        #expect(values.first?.gainDB == 3)
    }

    /// A shelf sitting at 0 dB isn't a trim — reporting it would put a
    /// permanent "Tone trim: Bass +0" line on the screen for anyone who ever
    /// ran `simple-eq --bass 0`.
    @Test func zeroedShelvesAreNotReported() {
        var bands: [EQBand] = []
        EQBandLookup.setGain(0, at: 250, bandwidth: ToneTrim.bandwidth,
                             filterType: .lowShelf, in: &bands)
        EQBandLookup.setGain(0, at: 5000, bandwidth: ToneTrim.bandwidth,
                             filterType: .highShelf, in: &bands)
        #expect(ToneTrim.offGridValues(in: bands).isEmpty)
    }

    @Test func noToneTrimReportsNothing() {
        #expect(ToneTrim.offGridValues(in: []).isEmpty)
    }

    @Test func bothShelvesReportInSlotOrder() {
        var bands: [EQBand] = []
        EQBandLookup.setGain(-2.5, at: 5000, bandwidth: ToneTrim.bandwidth,
                             filterType: .highShelf, in: &bands)
        EQBandLookup.setGain(4, at: 250, bandwidth: ToneTrim.bandwidth,
                             filterType: .lowShelf, in: &bands)

        let values = ToneTrim.offGridValues(in: bands)
        #expect(values.map(\.slot.key) == ["bass", "treble"], "bass before treble, low to high")
        #expect(values.map(\.gainDB) == [4, -2.5])
    }

    // MARK: - Shared definition

    /// `AppControlService` must read the same layout the Graphic surface owns.
    /// Two copies drifting apart is exactly how a tone band becomes an
    /// "other filter" again.
    @Test func appControlServiceUsesTheSharedLayout() {
        #expect(AppControlService.simpleSlots == ToneTrim.slots)
        #expect(AppControlService.simpleBandwidth == ToneTrim.bandwidth)
        #expect(AppControlService.simpleEQRange == ToneTrim.range)
    }
}
