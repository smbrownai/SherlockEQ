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
        .safeAreaInset(edge: .bottom) { footer }
    }

    /// Footer: the active-profile control plus a persistent, compact
    /// Health & Safety row. Health & Safety is a thin secondary row under the
    /// profile button so it never crowds or obscures the profile control —
    /// even at the app's minimum window height.
    @ViewBuilder private var footer: some View {
        VStack(spacing: 0) {
            profileShortcut
            Divider()
            healthSafetyRow
        }
    }

    /// Persistent Health & Safety access — reachable from every main screen,
    /// keyboard-operable, and understandable from its label alone (the icon is
    /// decorative). Opens the consolidated disclosure sheet.
    private var healthSafetyRow: some View {
        Button {
            audioState.showHealthSafety = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "heart.text.square")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("Health & Safety")
                    .font(.callout)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .help("What SherlockEQ is and isn't, safe use, and when to see a professional")
        .accessibilityLabel("Health and Safety")
        .accessibilityHint("Opens the health and safety information sheet")
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
