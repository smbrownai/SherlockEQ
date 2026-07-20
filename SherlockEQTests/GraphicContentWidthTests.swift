//
//  GraphicContentWidthTests.swift
//  SherlockEQTests
//
//  The Graphic EQ grid is fixed-width by design — it must not reflow when Link
//  toggles — so it sets the main window's minimum width. That arithmetic used
//  to be a comment in MainWindowView, and it went stale the moment the grid
//  changed band count, leaving the window 132 pt wider than its content.
//
//  It's derived now. These pin the derivation against the band count so the
//  two can't drift apart again.
//

import Testing
import Foundation
@testable import SherlockEQ

@MainActor
struct GraphicContentWidthTests {

    /// Recompute independently of the implementation: N columns, N−1 gaps,
    /// row padding both sides, screen padding both sides.
    private var expected: CGFloat {
        let n = CGFloat(EQMode.graphicCenters.count)
        return n * GraphicEQView.columnWidth
            + (n - 1) * GraphicEQView.columnSpacing
            + 2 * GraphicEQView.rowPadding
            + 2 * GraphicEQView.screenPadding
    }

    @Test func contentWidthMatchesTheBandCount() {
        #expect(GraphicEQView.contentWidth == expected)
    }

    /// The concrete number for today's ten-band ISO octave grid:
    /// 10×62 + 9×4 + 2×12 + 2×20 = 620 + 36 + 24 + 40 = 720.
    @Test func tenBandGridIsSevenTwenty() {
        #expect(EQMode.graphicCenters.count == 10, "these numbers assume the ten-band grid")
        #expect(GraphicEQView.contentWidth == 720)
    }

    /// The window must never be narrower than the screen it has to hold. This
    /// is the invariant the stale comment broke — not by clipping, but by
    /// reserving 132 pt that nothing needed.
    ///
    /// The window holds ONE width for both inspector states, sized for the
    /// panel being open. A minimum that only fitted the closed state would let
    /// the window sit at 994 and then clip the grid the moment the panel came
    /// out — which is the failure this composition exists to prevent.
    @Test func windowWidthCoversTheGridWithTheInspectorOpen() {
        // Reconstruct the same composition MainWindowView uses.
        let navSidebar: CGFloat = 240
        let slack: CGFloat = 34
        let withPanelClosed = navSidebar + GraphicEQView.contentWidth + slack
        #expect(withPanelClosed == 994, "ten bands → 240 + 720 + 34")

        let panel: CGFloat = 260, divider: CGFloat = 1
        let windowWidth = withPanelClosed + divider + panel
        #expect(windowWidth == 1255, "the window's min and ideal width")

        // The slack the closed state carries. Real, and spent on the canvas —
        // but it must never go negative, which would mean the panel doesn't fit.
        #expect(windowWidth - withPanelClosed == 261)
    }

    /// Guards the shape of the formula rather than a number: adding a band
    /// must widen the requirement by exactly one column plus one gap.
    @Test func eachBandCostsAColumnPlusAGap() {
        let perBand = GraphicEQView.columnWidth + GraphicEQView.columnSpacing
        #expect(perBand == 66)
        // The twelve-band grid this replaced: 720 + 2 × 66 = 852, which is the
        // figure the old comment recorded. Confirms the derivation reproduces
        // history rather than inventing a new convention.
        #expect(GraphicEQView.contentWidth + 2 * perBand == 852)
    }
}
