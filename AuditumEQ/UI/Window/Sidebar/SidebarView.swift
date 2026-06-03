import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSection?

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                ForEach(SidebarSection.librarySections) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            }

            Section("Diagnostics") {
                Label(SidebarSection.debug.title, systemImage: SidebarSection.debug.symbol)
                    .tag(SidebarSection.debug)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { profileShortcut }
    }

    @ViewBuilder private var profileShortcut: some View {
        // Quick jump to the Profiles section. Real CRUD lives in the section's
        // toolbar; this is just navigation.
        VStack(spacing: 0) {
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
}
