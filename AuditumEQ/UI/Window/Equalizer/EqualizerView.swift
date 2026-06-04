import SwiftUI

/// Equalizer section of the main window — three-tab container per spec §8.3.
/// Session 13 wires the Expert tab (parametric canvas + biquad math); the
/// Simple (3-band) and Advanced (10-band graphic) tabs land in Session 14.
struct EqualizerView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var audioState: AudioState

    private enum Tab: String, CaseIterable, Hashable {
        case simple = "Simple"
        case speech = "Speech"
        case advanced = "Advanced"
        case expert = "Expert"
    }
    @State private var tab: Tab = .expert

    var body: some View {
        let activeProfile = audioState.activeProfile(in: profileStore)
        let locked = activeProfile?.isBuiltIn ?? false

        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Divider().padding(.top, 12)

            if let profile = activeProfile, profile.isBuiltIn {
                BuiltInProfileBanner(profileName: profile.name) {
                    duplicateActive(profile)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }

            Group {
                switch tab {
                case .simple:   SimpleEQView()
                case .speech:   SpeechEQView()
                case .advanced: AdvancedEQView()
                case .expert:   ExpertEQView()
                }
            }
            .disabled(locked)
        }
        .navigationTitle("Equalizer")
    }

    private func duplicateActive(_ profile: HearingProfile) {
        var copy = profile.duplicated()
        copy.name = uniqueName(base: copy.name)
        do {
            try profileStore.save(copy)
            audioState.activeProfileID = copy.id
        } catch { /* surfaced via ProfileStore.lastError */ }
    }

    private func uniqueName(base: String) -> String {
        let existing = Set(profileStore.profiles.map(\.name))
        if !existing.contains(base) { return base }
        var i = 2
        while existing.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }
}
