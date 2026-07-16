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
                    description: Text("Make a profile active to use the Adaptive Comfort tools.")
                )
            }
        }
        .navigationTitle("Adaptive Comfort")
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
                presetRow(profile)
                separateToggleRow(profile)
                featureCards(profile)
                // The former "not a medical device" card is now the shared
                // compact chip → Health & Safety sheet (single source).
                HealthSafetyChip()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Quick-setup presets

    /// One-tap whole-panel setups (Dialogue / Gentle / Off), applied to both
    /// ears. The matching preset is highlighted; a custom mix shows none.
    @ViewBuilder
    private func presetRow(_ profile: HearingProfile) -> some View {
        let current = ComfortPreset.matching(profile.dynamics)
        HStack(spacing: 8) {
            Text("Quick setup")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(ComfortPreset.allCases) { preset in
                Button {
                    apply(preset, to: profile)
                } label: {
                    Label(preset.label, systemImage: preset.symbol)
                }
                .buttonStyle(.bordered)
                .tint(current == preset ? .accentColor : .secondary)
                .accessibilityLabel("\(preset.label) comfort preset")
                .accessibilityAddTraits(current == preset ? [.isSelected] : [])
            }
            Spacer()
            if current == nil {
                Text("Custom")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Apply a preset's settings to every feature on both ears (one undoable
    /// save). Presets are a quick global setup, so they write both ears
    /// regardless of the Separate-L/R toggle.
    private func apply(_ preset: ComfortPreset, to profile: HearingProfile) {
        var updated = profile
        for kind in DynamicFeatureKind.allCases {
            let settings = preset.settings(for: kind)
            updated.dynamics.setSettings(settings, for: kind, ear: .left)
            updated.dynamics.setSettings(settings, for: kind, ear: .right)
        }
        try? profileStore.save(updated, actionName: "Adaptive Comfort: \(preset.label)")
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
                        tint: audioState.preferences.leftEarColor,
                        activity: audioState.dynamicActivity
                    )
                    DynamicFeatureCard(
                        kind: kind,
                        settings: settingsBinding(profile, kind: kind, ear: .right, linked: false),
                        ear: .right,
                        earLabel: "Right ear",
                        tint: audioState.preferences.rightEarColor,
                        activity: audioState.dynamicActivity
                    )
                } else {
                    DynamicFeatureCard(
                        kind: kind,
                        settings: settingsBinding(profile, kind: kind, ear: .left, linked: true),
                        ear: .left,
                        earLabel: nil,
                        tint: .accentColor,
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
            Toggle("Adjust ears separately", isOn: Binding(
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
