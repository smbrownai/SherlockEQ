import SwiftUI

/// Root view of the main application window. Sidebar-based navigation modeled
/// on macOS System Settings (spec §8.3). Sections beyond Debug are placeholders
/// in Session 6; Sessions 7–17 fill them in incrementally.
struct MainWindowView: View {
    @State private var selection: SidebarSection? = .profiles

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 560, ideal: 640)
        }
        .frame(minWidth: 860, minHeight: 600)
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .profiles {
        case .profiles:      ProfilesView()
        case .audiogram:     AudiogramView()
        case .equalizer:     EqualizerView()
        case .toneFinder:    ToneFinderView()
        case .safeListening: SafeListeningView()
        case .settings:      SettingsView()
        case .debug:         DebugView()
        }
    }
}
