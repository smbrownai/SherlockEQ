import SwiftUI

/// Profile picker row for the popover. Lists every persisted profile, with
/// the currently-active one selected.
struct ProfilePickerRow: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore

    var body: some View {
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
        }
    }

    private var activeName: String {
        audioState.activeProfile(in: profileStore)?.name ?? "—"
    }

    private var activeSymbol: String {
        audioState.activeProfile(in: profileStore)?.symbol ?? "questionmark.circle"
    }
}
