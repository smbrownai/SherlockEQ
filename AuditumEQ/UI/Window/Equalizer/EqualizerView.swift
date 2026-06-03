import SwiftUI

/// Equalizer section of the main window — three-tab container per spec §8.3.
/// Session 13 wires the Expert tab (parametric canvas + biquad math); the
/// Simple (3-band) and Advanced (10-band graphic) tabs land in Session 14.
struct EqualizerView: View {
    private enum Tab: String, CaseIterable, Hashable {
        case simple = "Simple"
        case advanced = "Advanced"
        case expert = "Expert"
    }
    @State private var tab: Tab = .expert

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Divider().padding(.top, 12)

            switch tab {
            case .simple:   SimpleEQView()
            case .advanced: AdvancedEQView()
            case .expert:   ExpertEQView()
            }
        }
        .navigationTitle("Equalizer")
    }
}
