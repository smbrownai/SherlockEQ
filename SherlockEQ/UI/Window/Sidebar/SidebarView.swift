import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSection?
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore

    var body: some View {
        List(selection: $selection) {
            Section("Audio Processing") {
                ForEach(SidebarSection.audioProcessorSections) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            }

            Section("App") {
                ForEach(SidebarSection.appSections) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { profileShortcut }
    }

    @ViewBuilder private var profileShortcut: some View {
        // Active profile name (read-only label) sits above the "Manage
        // Profiles" jump so the user always knows what's loaded — the
        // sidebar is the most persistent surface in the window, and
        // the active profile drives every audio decision downstream.
        // Real CRUD lives in the section's toolbar; the button is just
        // navigation.
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Active profile")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(activeProfileName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .accessibilityElement(children: .combine)

            Divider()

            Button(action: { selection = .profiles }) {
                Label("Manage Profiles", systemImage: "person.crop.circle.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .help("Open the Profiles section")
        }
    }

    private var activeProfileName: String {
        audioState.activeProfile(in: profileStore)?.name ?? "None"
    }
}
