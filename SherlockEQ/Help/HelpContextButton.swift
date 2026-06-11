import SwiftUI

/// A small, unobtrusive `?` button that opens a specific help topic in
/// the SherlockEQ Help window. Used sparingly next to features that are
/// easy to misunderstand (audiogram entry, tinnitus tone matching, VU
/// metering, AutoEQ import, gain/safety, the Analog Control Unit).
///
/// It routes through `HelpCenter.shared`, so it needs no environment
/// wiring and works identically from the main window, the popover, and
/// the standalone Analog Control Unit window.
struct HelpContextButton: View {
    let topic: HelpTopic
    /// Spoken / hover description, e.g. "audiogram entry".
    var label: String

    init(_ topic: HelpTopic, label: String) {
        self.topic = topic
        self.label = label
    }

    var body: some View {
        Button {
            HelpCenter.shared.open(topic: topic)
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help("Help: \(label)")
        .accessibilityLabel("Help about \(label)")
    }
}
