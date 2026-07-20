import SwiftUI

/// Root view of the main application window. Sidebar-based navigation modeled
/// on macOS System Settings (spec §8.3). Sections beyond Debug are placeholders
/// in Session 6; Sessions 7–17 fill them in incrementally.
struct MainWindowView: View {
    @EnvironmentObject private var audioState: AudioState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: SidebarSection? = .profiles
    /// Visibility of the right-hand monitoring inspector. Persistent
    /// across launches via @AppStorage — the user's open/closed choice
    /// sticks. Defaults to **closed**: the panel mostly repeated a
    /// low-information idle state while consuming ~240 pt on every screen,
    /// so it opens on demand as an inspector via `MonitorToggleButton`.
    @AppStorage("sherlockeq.monitorSidebarVisible") private var monitorSidebarVisible: Bool = false

    // MARK: - Window minimums

    /// Fixed nav sidebar, the monitor inspector, and the divider between them.
    private static let navSidebarWidth: CGFloat = 240
    private static let monitorPanelWidth: CGFloat = 260
    private static let panelDividerWidth: CGFloat = 1
    /// Breathing room past the Graphic grid so it isn't flush to both edges at
    /// the minimum. Historically 34 pt; kept deliberately.
    private static let detailSlack: CGFloat = 34

    /// The detail column can't go narrower than the Graphic EQ screen, which
    /// is the widest and is fixed-width by design so it can't reflow.
    ///
    /// Derived from `GraphicEQView.contentWidth` rather than restated. The
    /// arithmetic used to live here as a comment, and when the grid dropped
    /// from twelve bands to ten it wasn't updated — leaving the window 132 pt
    /// wider than anything in it required, with the stale comment still
    /// confidently explaining the old number.
    private static var detailMinWidth: CGFloat {
        GraphicEQView.contentWidth + detailSlack
    }

    /// What the window needs with the monitor inspector closed — 994 pt on
    /// today's ten-band grid. Not the window minimum; see below.
    private static var widthWithPanelClosed: CGFloat {
        navSidebarWidth + detailMinWidth
    }

    /// The window minimum, and also its ideal.
    ///
    /// Sized for the inspector being **open**, not closed. The panel is an
    /// inspector inside the detail column, so it takes its width straight out
    /// of the content: a minimum that only fitted the closed state would let
    /// the user drag the window down to 994 and then clip the slider grid the
    /// moment they opened the panel. Holding one width for both states costs
    /// 261 pt of slack while the panel is closed — which the EQ canvas and the
    /// profile screens use — and makes the panel a toggle that can never fail.
    ///
    /// Used as `idealWidth` too, so a first launch opens at exactly the size
    /// the app actually wants rather than the old 1400, which was a guess with
    /// no relationship to the content.
    private static var windowWidth: CGFloat {
        widthWithPanelClosed + panelDividerWidth + monitorPanelWidth
    }

    /// Height is a comfort choice rather than a constraint: the Graphic and
    /// Audiogram screens both sit inside `ScrollView`s, so tall content scrolls
    /// instead of clipping. 760 keeps the window inside a 1280×800 display once
    /// the menu bar takes its ~25 pt; 800 is the roomier default.
    private static let windowMinHeight: CGFloat = 760
    private static let windowIdealHeight: CGFloat = 800

    var body: some View {
        // Lock the sidebar visible: the seven sections + active-profile
        // chip + Manage Profiles button are the app's primary navigation
        // and there's no surface where hiding them helps. `.constant(.all)`
        // pins the column open against keyboard shortcuts / system gestures
        // that would otherwise collapse it; `.toolbar(removing: .sidebarToggle)`
        // on the sidebar view stops AppKit from synthesizing a toggle
        // button anywhere in the title bar.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(selection: $selection)
                // Force the sidebar's intrinsic content width to 240
                // pt. `.navigationSplitViewColumnWidth` is advisory on
                // macOS — SwiftUI ignores even the min/ideal/max
                // triple, picking a narrower default and letting the
                // user drag freely. A hard `.frame(width:)` on the
                // *content* gives it an intrinsic size the enclosing
                // column has to honor (shrinking past it would clip
                // the content). The navigation-split modifier stays
                // as a hint to the layout system in case a future
                // SwiftUI release starts honoring it.
                .frame(width: 240)
                .navigationSplitViewColumnWidth(min: 240, ideal: 240, max: 240)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                if let notice = audioState.noticeCenter.userVisibleNotice {
                    NoticeBannerView(notice: notice) {
                        audioState.dismissNotice()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                // The monitor panel slides in as an in-layout trailing
                // column — collapsed by default, opened from the toolbar
                // status. Kept inside the detail area (rather than SwiftUI's
                // native `.inspector`, which resized/shifted the whole
                // window and animated jerkily): here nothing outside the
                // detail moves, so both gutters stay aligned and the slide
                // is smooth. The StereoMonitor 60 Hz loop stays refcount-
                // gated on the panel's onAppear/onDisappear, idle while
                // collapsed.
                HStack(spacing: 0) {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if monitorSidebarVisible {
                        Divider()
                        MonitorSidebar()
                            .frame(width: 260)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            // Skip the slide / banner animations when Reduce Motion is on —
            // the System Settings toggle exists exactly so users prone to
            // vestibular triggers can disable transitions like these.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: monitorSidebarVisible)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: audioState.noticeCenter.userVisibleNotice)
            // Soft scroll-edge fade where detail content (the EQ screens'
            // ScrollViews) passes under the Liquid Glass toolbar (Tahoe+).
            .softTopScrollEdge()
            .navigationSplitViewColumnWidth(min: 760, ideal: 820)
        }
        .toolbar {
            // Reference Mode lives globally in the title bar so the user
            // can A/B against the source signal from any screen, not just
            // the Equalizer view. Declared before the monitor toggle so
            // it sits to its left on macOS (primaryAction items render in
            // declaration order, left → right). On Tahoe, `ToolbarSpacer`
            // (not a plain Spacer-in-ToolbarItem) splits the two unrelated
            // controls into separate Liquid Glass clusters instead of one
            // undifferentiated capsule; Sonoma keeps the plain spacer.
            ToolbarItem(placement: .primaryAction) {
                EQBypassButton()
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Spacer()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                // Show/hide the monitor panel. Defaults hidden.
                MonitorToggleButton(isOpen: monitorSidebarVisible) {
                    monitorSidebarVisible.toggle()
                }
            }
        }
        // One width for both inspector states — see `windowWidth`. The
        // previous per-state minimum let the window sit at the closed width
        // and then clip when the panel opened.
        .frame(minWidth: Self.windowWidth,
               idealWidth: Self.windowWidth,
               minHeight: Self.windowMinHeight,
               idealHeight: Self.windowIdealHeight)
        .linkUndoManagerToProfileStore()
        // Honor cross-window deep-link requests (e.g. the onboarding wizard's
        // "next steps" cards). `onAppear` catches an intent set before this
        // window existed (the wizard opens the window then asks for a section);
        // `onChange` catches one set while it's already open. Clear after
        // applying so re-selecting the same section later still works.
        .onAppear { applyPendingSection() }
        .onChange(of: audioState.pendingMainSection) { applyPendingSection() }
    }

    private func applyPendingSection() {
        guard let target = audioState.pendingMainSection else { return }
        selection = target
        audioState.pendingMainSection = nil
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .profiles {
        case .profiles:      ProfilesView()
        case .audiogram:     AudiogramView()
        case .equalizer:     EqualizerView()
        case .toneFinder:    ToneFinderView()
        case .clarity:       ClarityView()
        case .safeListening: SafeListeningView()
        case .healthSafety:  HealthSafetyView()
        case .settings:      SettingsView()
        case .debug:         DebugView()
        }
    }
}

/// Toolbar toggle for the monitor panel (`MonitorSidebar`), which holds app
/// master gain, active-profile balance, and today's exposure — each with its
/// explicit scope label. Deliberately just a toggle: it briefly carried a live
/// gain/balance/exposure readout in the title bar, but those numbers duplicated
/// the panel they open and earned their space nowhere. The panel defaults to
/// hidden and its open/closed state persists.
private struct MonitorToggleButton: View {
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isOpen ? "sidebar.right" : "sidebar.squares.right")
                .imageScale(.medium)
        }
        .help(isOpen ? "Hide the monitor panel"
                     : "Show the monitor panel — app master gain, active-profile balance, and today's exposure")
        .accessibilityLabel(isOpen ? "Hide monitor panel" : "Show monitor panel")
    }
}
