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
        .safeAreaInset(edge: .bottom) { newProfileBar }
    }

    @ViewBuilder private var newProfileBar: some View {
        // Placeholder — full profile CRUD comes in Session 7. Button is shown
        // disabled so the sidebar's visual structure already matches §8.3.
        VStack(spacing: 0) {
            Divider()
            Button(action: {}) {
                Label("New Profile", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .help("Profile creation lands in Session 7")
        }
    }
}
