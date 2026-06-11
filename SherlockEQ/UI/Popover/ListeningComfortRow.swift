import SwiftUI

/// Popover row for the Listening Comfort stage: on/off toggle + a count
/// of how many processors are active. Per-processor Strength / Sensitivity
/// and per-ear control live on the Listening Comfort (Clarity) screen.
///
/// Mirrors `TinnitusNotchRow`: writes the **active profile's** own
/// per-feature `enabled` flags (not the global `dynamicsEnabled` stage
/// flag), so the on/off state travels with the profile. The global stage
/// toggle is on by default and gates audibility the same way
/// `notchFilterEnabled` gates the notch.
///
/// Like the notch toggle, this is deliberately coarse: "On" means any of
/// the three processors is enabled on either ear, and flipping the switch
/// writes all of them in lockstep, leaving each processor's Strength and
/// Sensitivity untouched. One consequence the single-filter notch doesn't
/// have: turning Comfort on enables all three processors. A user who wants
/// only a subset manages that on the Listening Comfort screen.
struct ListeningComfortRow: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore

    var body: some View {
        HStack(spacing: 8) {
            Text("Listening Comfort")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 100, alignment: .leading)
                .layoutPriority(1)

            Toggle("", isOn: toggleBinding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()

            Spacer(minLength: 0)

            Text(activityLabel)
                .font(.caption.monospaced())
                .foregroundStyle(comfortEnabled ? .primary : .tertiary)
        }
        .disabled(audioState.activeProfile(in: profileStore) == nil)
    }

    /// "On" when any processor is enabled on either ear. The popover is
    /// the 5-second surface; the per-processor, per-ear story lives on the
    /// Listening Comfort screen, so we keep this binary.
    private var comfortEnabled: Bool {
        audioState.activeProfile(in: profileStore)?.dynamics.hasAnyEnabled ?? false
    }

    /// Number of processors (of three) active on at least one ear — the
    /// notch shows its frequency here; comfort has no single value, so a
    /// count is the glanceable summary. "Off" when none are active.
    private var activityLabel: String {
        guard let profile = audioState.activeProfile(in: profileStore) else { return "—" }
        let active = DynamicFeatureKind.allCases.filter { kind in
            profile.dynamics.settings(for: kind, ear: .left).enabled
                || profile.dynamics.settings(for: kind, ear: .right).enabled
        }.count
        return active == 0 ? "Off" : "\(active) active"
    }

    /// Quick toggle writes every processor on both ears in lockstep,
    /// regardless of `separateChannels` — the popover is for "turn it on" /
    /// "turn it off", not fine per-ear management. Strength and Sensitivity
    /// are preserved so the processors keep their dialed-in character.
    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { comfortEnabled },
            set: { newValue in
                guard var p = audioState.activeProfile(in: profileStore) else { return }
                for kind in DynamicFeatureKind.allCases {
                    for ear in [EQBandLookup.Ear.left, .right] {
                        var settings = p.dynamics.settings(for: kind, ear: ear)
                        settings.enabled = newValue
                        p.dynamics.setSettings(settings, for: kind, ear: ear)
                    }
                }
                try? profileStore.save(p)
            }
        )
    }
}
