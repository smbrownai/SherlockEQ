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
        // Sized so the Expert layer-chip strip (Lens + 6 chips: Output /
        // Input / EQ / Audiogram / Safety / Peaks) fits on one row at the
        // default Dynamic Type size, with the existing top header bar
        // (ear picker + viz picker + bands badge + Q/Oct + Link L+R + Add
        // band) above it — and a sidebar wide enough that section labels
        // never truncate. Height accommodates the chip strip plus a
        // comfortable canvas plus the controls bar + Tinnitus notch
        // section without forcing a scroll on default-size windows.
        .frame(minWidth: 1180, idealWidth: 1240, minHeight: 740, idealHeight: 820)
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
