import SwiftUI

/// Root view of the main application window. Sidebar-based navigation modeled
/// on macOS System Settings (spec §8.3). Sections beyond Debug are placeholders
/// in Session 6; Sessions 7–17 fill them in incrementally.
struct MainWindowView: View {
    @State private var selection: SidebarSection? = .profiles

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 760, ideal: 820)
        }
        // Sized for Advanced's 10-band slider row (10 × 60 pt + padding) on
        // top of the spectrum canvas + comfortable sidebar that never
        // truncates its section labels.
        .frame(minWidth: 1020, idealWidth: 1100, minHeight: 680, idealHeight: 740)
        .linkUndoManagerToProfileStore()
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .profiles {
        case .profiles:      ProfilesView()
        case .audiogram:     AudiogramView()
        case .equalizer:     EqualizerView()
        case .toneFinder:    ToneFinderView()
        case .safeListening: SafeListeningView()
        case .meters:        MetersView()
        case .settings:      SettingsView()
        case .debug:         DebugView()
        }
    }
}
