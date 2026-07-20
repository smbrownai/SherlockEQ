//
//  GraphicConversionTests.swift
//  SherlockEQTests
//
//  The "Convert to Graphic EQ" fit (phase3-make-correction-land.md §1.4):
//  off-grid filters are approximated by the 12 one-octave graphic bells via
//  a damped fixed-point solve, so the realised curve matches the source
//  composite — not a naive per-point copy that over-shoots where bells
//  overlap.
//

import Testing
import Foundation
@testable import SherlockEQ

struct GraphicConversionTests {

    private func band(
        hz: Double, gainDB: Double, q: Double = 1.0,
        type: EQFilterType = .parametric
    ) -> EQBand {
        EQBand(frequencyHz: hz, gaindB: gainDB, bandwidth: q, filterType: type, enabled: true)
    }

    private func fittedBands(_ gains: [Double]) -> [EQBand] {
        zip(EQMode.graphicCenters, gains).compactMap { center, gain in
            gain == 0 ? nil : band(hz: center, gainDB: gain)
        }
    }

    /// Max |source − fitted| composite error over a log sweep of the range.
    private func maxErrorDB(
        source: [EQBand], gains: [Double],
        fromHz: Double, toHz: Double, points: Int = 120
    ) -> Double {
        let fitted = fittedBands(gains)
        var worst = 0.0
        for i in 0..<points {
            let frac = Double(i) / Double(points - 1)
            let hz = fromHz * pow(toHz / fromHz, frac)
            let want = BiquadResponse.compositeMagnitudeDB(at: hz, bands: source)
            let got = BiquadResponse.compositeMagnitudeDB(at: hz, bands: fitted)
            worst = max(worst, abs(want - got))
        }
        return worst
    }

    @Test func emptyInputFitsToAllZeros() {
        #expect(GraphicConversion.fittedGains(for: []) == Array(repeating: 0, count: EQMode.graphicCenters.count))
    }

    @Test func offGridParametricBandFitsTightly() {
        // 2.5 kHz +6 dB — now between the 2k and 4k sliders, a full octave
        // apart since 3k left the grid. A coarser grid fits a narrow off-grid
        // bell less tightly, so the tolerance is looser than the 12-band era's
        // 1.5 dB by design, not by drift.
        let source = [band(hz: 2500, gainDB: 6)]
        let gains = GraphicConversion.fittedGains(for: source)
        #expect(maxErrorDB(source: source, gains: gains, fromHz: 100, toHz: 16_000) < 2.0)
    }

    @Test func simpleModeToneStackFitsWithinTolerance() {
        // The retired Simple mode's shape: bass/treble shelves + mid bell.
        // Shelf plateaus at the spectrum edges are the hard part for
        // peaking bells — tolerance is looser there (checked from 40 Hz,
        // where program material lives, not from 20 Hz).
        let source = [
            band(hz: 250, gainDB: 4, type: .lowShelf),
            band(hz: 1000, gainDB: 3),
            band(hz: 5000, gainDB: -4, type: .highShelf),
        ]
        let gains = GraphicConversion.fittedGains(for: source)
        #expect(maxErrorDB(source: source, gains: gains, fromHz: 40, toHz: 16_000) < 2.0)
        // At the graphic centers themselves the fit should be tight.
        for center in EQMode.graphicCenters where center >= 40 {
            let want = BiquadResponse.compositeMagnitudeDB(at: center, bands: source)
            let got = BiquadResponse.compositeMagnitudeDB(at: center, bands: fittedBands(gains))
            #expect(abs(want - got) < 1.0, "center \(center)")
        }
    }

    @Test func speechModeBandsFitWithinTolerance() {
        // The retired Speech mode's six slots at representative gains.
        let source = [
            band(hz: 60, gainDB: -3, type: .lowShelf),
            band(hz: 200, gainDB: 2),
            band(hz: 800, gainDB: 1.5),
            band(hz: 2500, gainDB: 4),
            band(hz: 6000, gainDB: -2),
            band(hz: 12_000, gainDB: 2, type: .highShelf),
        ]
        let gains = GraphicConversion.fittedGains(for: source)
        #expect(maxErrorDB(source: source, gains: gains, fromHz: 40, toHz: 16_000) < 2.0)
    }

    @Test func fittedGainsClampToSliderRange() {
        let source = [band(hz: 1000, gainDB: 20)]
        let gains = GraphicConversion.fittedGains(for: source)
        #expect(gains.allSatisfy { GraphicConversion.sliderRangeDB.contains($0) })
        #expect(gains.max() ?? 0 == GraphicConversion.sliderRangeDB.upperBound)
    }

    @Test func negligibleContributionsSnapToZero() {
        // A band far outside the audible fit range shouldn't smear tiny
        // residues across every slider.
        let source = [band(hz: 1000, gainDB: 6, q: 8.0)]  // very narrow
        let gains = GraphicConversion.fittedGains(for: source)
        // Distant sliders (31.5, 16k) must be exactly 0, not 0.02.
        #expect(gains.first == 0)
        #expect(gains.last == 0)
    }
}
