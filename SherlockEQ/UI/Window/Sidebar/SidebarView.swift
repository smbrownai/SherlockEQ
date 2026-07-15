import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSection?
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore

    var body: some View {
        List(selection: $selection) {
            Section("Sound") {
                ForEach(SidebarSection.soundSections) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            }

            Section("Comfort & Safety") {
                ForEach(SidebarSection.comfortSafetySections) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            }

            Section("App") {
                ForEach(SidebarSection.appSections(showDebug: audioState.preferences.showDebugInSidebar)) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { profileShortcut }
    }

    /// The active-profile footer is itself the clickable control that opens
    /// profile management — one button (profile name + a chevron affordance)
    /// so it's obvious it's tappable, rather than a read-only label sitting
    /// above a separate "Manage Profiles" row.
    @ViewBuilder private var profileShortcut: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: { selection = .profiles }) {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Active profile")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(activeProfileName)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .help("Manage profiles — create, duplicate, import, or switch the active profile")
            .accessibilityLabel("Active profile: \(activeProfileName). Manage profiles")
        }
    }

    private var activeProfileName: String {
        audioState.activeProfile(in: profileStore)?.name ?? "None"
    }
}
