import SwiftUI

struct EqualizerView: View {
    var body: some View {
        PlaceholderView(
            title: "Equalizer",
            summary: "Three tabs: Simple (3-band bass/mids/treble), Advanced (10-band graphic, L/R columns), and Expert (parametric canvas with draggable nodes, spectrum analyzer, tinnitus notch, AutoEQ).",
            sessionRef: "Sessions 9, 13, 14",
            symbol: "slider.horizontal.3"
        )
    }
}
