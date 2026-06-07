import SwiftUI

/// Root view of the main application window. Sidebar-based navigation modeled
/// on macOS System Settings (spec §8.3). Sections beyond Debug are placeholders
/// in Session 6; Sessions 7–17 fill them in incrementally.
struct MainWindowView: View {
    @EnvironmentObject private var audioState: AudioState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: SidebarSection? = .profiles
    /// Visibility of the right-hand monitoring sidebar. Persistent across
    /// launches via @AppStorage — users who dismiss it stay dismissed
    /// until they re-open it from the toolbar. Defaults to visible so
    /// first-launch users discover the level / volume / balance / dose
    /// monitoring panel without having to find a hidden toggle.
    @AppStorage("sherlockeq.monitorSidebarVisible") private var monitorSidebarVisible: Bool = true

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if let notice = audioState.userVisibleNotice {
                    NoticeBannerView(notice: notice) {
                        audioState.dismissNotice()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                HStack(spacing: 0) {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if monitorSidebarVisible {
                        Divider()
                        MonitorSidebar()
                            .frame(width: 220)
                            // Slide in / out smoothly when the toolbar toggle
                            // flips. The transition is purely visual; the
                            // underlying StereoMonitor subscription is keyed
                            // on the view's lifecycle (onAppear/onDisappear).
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            // Skip animations entirely when Reduce Motion is on — the
            // System Settings toggle exists exactly so users prone to
            // vestibular triggers can disable transitions like the
            // sidebar slide and the banner drop-in.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: monitorSidebarVisible)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: audioState.userVisibleNotice)
            .navigationSplitViewColumnWidth(min: 760, ideal: 820)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    monitorSidebarVisible.toggle()
                } label: {
                    Image(systemName: monitorSidebarVisible
                          ? "sidebar.right"
                          : "sidebar.squares.right")
                }
                .help(monitorSidebarVisible ? "Hide monitor panel" : "Show monitor panel")
                .accessibilityLabel(monitorSidebarVisible ? "Hide monitor panel" : "Show monitor panel")
            }
        }
        // Sized so the Expert layer-chip strip (Lens + 6 chips: Output /
        // Input / EQ / Audiogram / Safety / Peaks) fits on one row at the
        // default Dynamic Type size, with the existing top header bar
        // (ear picker + viz picker + bands badge + Q/Oct + Link L+R + Add
        // band) above it, the main sidebar at left, AND the persistent
        // 220pt monitor sidebar at right. Width bumped 1180 → 1400 to
        // accommodate the new right column without compressing the
        // detail content.
        .frame(minWidth: 1400, idealWidth: 1480, minHeight: 740, idealHeight: 820)
        .linkUndoManagerToProfileStore()
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
