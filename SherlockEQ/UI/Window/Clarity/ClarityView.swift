import SwiftUI

/// Clarity panel — the user-facing surface for the level-dependent
/// ("dynamic") EQ features: Speech Presence, Harshness Control, and
/// Sibilance Tamer. Each is a named, preconfigured processor with just an
/// enable toggle plus Strength and Sensitivity sliders; the DSP constants
/// behind them live in `DynamicFeatureKind`. Per-ear independence mirrors
/// the Tinnitus Notch screen's Separate-L/R behaviour.
struct ClarityView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var audioState: AudioState

    private typealias Ear = EQBandLookup.Ear

    var body: some View {
        Group {
            if let profile = audioState.activeProfile(in: profileStore) {
                content(profile)
            } else {
                ContentUnavailableView(
                    "No active profile",
                    systemImage: "waveform.badge.magnifyingglass",
                    description: Text("Make a profile active to use the Listening Comfort tools.")
                )
            }
        }
        .navigationTitle("Listening Comfort")
        // The activity meters poll the dynamic processors at ~15 Hz only
        // while this panel is on screen.
        .onAppear { audioState.dynamicActivity.subscribe() }
        .onDisappear { audioState.dynamicActivity.unsubscribe() }
    }

    @ViewBuilder
    private func content(_ profile: HearingProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                introCard
                separateToggleRow(profile)
                featureCards(profile)
                disclaimer
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private func featureCards(_ profile: HearingProfile) -> some View {
        let separate = profile.dynamics.separateChannels
        VStack(spacing: 16) {
            ForEach(DynamicFeatureKind.allCases) { kind in
                if separate {
                    DynamicFeatureCard(
                        kind: kind,
                        settings: settingsBinding(profile, kind: kind, ear: .left, linked: false),
                        ear: .left,
                        earLabel: "Left ear",
                        tint: audioState.leftEarColor,
                        showHelp: true,
                        activity: audioState.dynamicActivity
                    )
                    DynamicFeatureCard(
                        kind: kind,
                        settings: settingsBinding(profile, kind: kind, ear: .right, linked: false),
                        ear: .right,
                        earLabel: "Right ear",
                        tint: audioState.rightEarColor,
                        showHelp: false,
                        activity: audioState.dynamicActivity
                    )
                } else {
                    DynamicFeatureCard(
                        kind: kind,
                        settings: settingsBinding(profile, kind: kind, ear: .left, linked: true),
                        ear: .left,
                        earLabel: nil,
                        tint: .accentColor,
                        showHelp: true,
                        activity: audioState.dynamicActivity
                    )
                }
            }
        }
    }

    // MARK: - Header rows

    private var introCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("Shape sound only when it needs it")
                    .font(.title3.weight(.semibold))
                Text("These tools listen to the audio and adjust the level just while a triggering sound is present — softening harsh moments or lifting voices — instead of permanently re-tuning everything.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func separateToggleRow(_ profile: HearingProfile) -> some View {
        HStack {
            Toggle("Separate L + R", isOn: Binding(
                get: { profile.dynamics.separateChannels },
                set: { newValue in
                    var updated = profile
                    updated.dynamics.separateChannels = newValue
                    // Snap right to left when turning separate off, so the
                    // shared card reflects what the user has been editing.
                    if !newValue {
                        for kind in DynamicFeatureKind.allCases {
                            let left = updated.dynamics.settings(for: kind, ear: .left)
                            updated.dynamics.setSettings(left, for: kind, ear: .right)
                        }
                    }
                    try? profileStore.save(updated)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            Spacer()
            Text("Tune each ear independently.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var disclaimer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Comfort and clarity, not a medical device", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("These tools shape audio for comfort and clarity. SherlockEQ is not a hearing aid or a medical device.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    // MARK: - Bindings

    /// Binding to one (kind, ear) feature's settings. Writes go through
    /// `ProfileStore.save` (inheriting the 500 ms undo coalescing). When
    /// `linked`, every write mirrors to both ears so the engine never sees
    /// an asymmetric intermediate state.
    private func settingsBinding(
        _ profile: HearingProfile,
        kind: DynamicFeatureKind,
        ear: Ear,
        linked: Bool
    ) -> Binding<DynamicFeatureSettings> {
        Binding(
            get: { profile.dynamics.settings(for: kind, ear: ear) },
            set: { newValue in
                var updated = profile
                if linked {
                    updated.dynamics.setSettings(newValue, for: kind, ear: .left)
                    updated.dynamics.setSettings(newValue, for: kind, ear: .right)
                } else {
                    updated.dynamics.setSettings(newValue, for: kind, ear: ear)
                }
                try? profileStore.save(updated)
            }
        )
    }
}
