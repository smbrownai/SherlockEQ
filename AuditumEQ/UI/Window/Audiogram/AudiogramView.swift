import SwiftUI

struct AudiogramView: View {
    var body: some View {
        PlaceholderView(
            title: "Audiogram",
            summary: "Interactive draggable threshold chart for the active profile, per ear. Numeric entry alongside the chart; resulting EQ curve previewed below.",
            sessionRef: "Session 8",
            symbol: "ear"
        )
    }
}
