import SwiftUI

/// Profile picker row for the popover. Lists every persisted profile, with
/// the currently-active one selected.
struct ProfilePickerRow: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore

    private var hasActiveProfile: Bool {
        audioState.activeProfile(in: profileStore) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Profile")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)

                Menu {
                    ForEach(profileStore.profiles) { profile in
                        Button {
                            audioState.activeProfileID = profile.id
                        } label: {
                            Label(profile.name, systemImage: profile.symbol)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: activeSymbol).frame(width: 14)
                        Text(activeName).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                // Subtle visual emphasis when there's nothing
                // selected — the menu reads as "missing input" rather
                // than just an em-dash placeholder.
                .overlay(
                    hasActiveProfile
                        ? nil
                        : RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.orange.opacity(0.5), lineWidth: 1)
                            .padding(-2)
                )
            }

            // Inline empty-state guidance. Without this the user just
            // sees "—" and has no signal that EQ is doing nothing.
            // applyActiveProfile already flattens the chain when no
            // profile resolves (recovery audit item 8); this surface
            // makes the consequence visible and points at the fix.
            if !hasActiveProfile {
                Label(
                    profileStore.profiles.isEmpty
                        ? "No profiles yet — open AuditumEQ to create one."
                        : "No profile selected — pick one above to enable EQ.",
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    profileStore.profiles.isEmpty
                        ? "No profiles exist. Open AuditumEQ from the menu bar arrow to create one."
                        : "No profile is currently active. Pick one from the menu above to enable EQ."
                )
            }
        }
    }

    private var activeName: String {
        audioState.activeProfile(in: profileStore)?.name ?? "None selected"
    }

    private var activeSymbol: String {
        audioState.activeProfile(in: profileStore)?.symbol ?? "questionmark.circle"
    }
}
