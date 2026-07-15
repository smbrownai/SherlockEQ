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
    /// so the live glance now lives in the compact toolbar status
    /// (`MonitorStatusButton`) and the full panel opens on demand as an
    /// inspector.
    @AppStorage("sherlockeq.monitorSidebarVisible") private var monitorSidebarVisible: Bool = false

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
                // Compact live glance — app master gain, today's exposure,
                // active-profile balance — that also opens the full panel.
                // Replaces the old show/hide toggle: the panel's usual state
                // was idle, so the values it carried belong in the title bar
                // and the controls behind a click.
                MonitorStatusButton(isOpen: monitorSidebarVisible) {
                    monitorSidebarVisible.toggle()
                }
            }
        }
        // Sized so the Expert layer-chip strip (Output / Input / Result /
        // EQ / Correction / Safety chips) fits on one row at the default
        // Dynamic Type size, with the top header bar (ear picker + bands
        // badge + Q/Oct + Link L+R + Add band) above it and the main
        // sidebar at left. The monitor panel is no longer a persistent
        // gutter — it opens as an inspector — so the minimum drops by its
        // former 240 pt; the ideal keeps room for the inspector open.
        .frame(minWidth: 1126, idealWidth: 1400, minHeight: 716, idealHeight: 800)
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
        case .settings:      SettingsView()
        case .debug:         DebugView()
        }
    }
}

/// Compact title-bar glance at the three values the monitor panel used to
/// hold open a whole gutter for: **app master gain**, **today's exposure**,
/// and **active-profile balance**. Clicking it opens (or closes) the full
/// `MonitorSidebar` as an inspector, where each value carries its explicit
/// scope label — resolving the "is this global or per-profile?" ambiguity
/// that the bare sliders created across the popover, Settings, and Profile
/// Detail. Reads only slow-changing state, so it never drives the 60 Hz VU
/// loop (that stays gated on the panel itself).
private struct MonitorStatusButton: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore

    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: isOpen ? "sidebar.right" : "sidebar.squares.right")
                    .imageScale(.medium)
                HStack(spacing: 5) {
                    labeled("Output", gainText)
                    bullet
                    labeled("Dose", doseText, tint: doseColor)
                    bullet
                    Text(balanceText)
                }
                .font(.callout)
                .monospacedDigit()
            }
        }
        .help(isOpen
              ? "Hide the monitor panel"
              : "Show the monitor panel — app master gain, active-profile balance, and today's exposure")
        .accessibilityLabel(isOpen ? "Hide monitor panel" : "Show monitor panel")
        .accessibilityValue(accessibilityValue)
    }

    private func labeled(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        HStack(spacing: 3) {
            Text("\(label):").foregroundStyle(.secondary)
            Text(value).foregroundStyle(tint ?? .primary)
        }
    }

    private var bullet: some View {
        Text("•").foregroundStyle(.tertiary)
    }

    // MARK: - Values (mirrors MonitorSidebar's formatting so the glance and
    // the panel never disagree)

    private var gainText: String {
        let dB = audioState.engineParameters.masterGainDB
        let magnitude = abs(dB)
        if magnitude < 0.05 { return "0 dB" }
        return String(format: "%@%.1f dB", dB > 0 ? "+" : "−", magnitude)
    }

    private var doseText: String {
        String(format: "%.0f%%", audioState.sessionDosePercent * 100)
    }

    private var balanceText: String {
        guard let profile = audioState.activeProfile(in: profileStore) else { return "—" }
        let b = profile.balance
        if abs(b) < 0.005 { return "Centered" }
        return b > 0 ? String(format: "R %.0f%%", b * 100)
                     : String(format: "L %.0f%%", abs(b) * 100)
    }

    private var doseColor: Color {
        switch audioState.safeListening.doseSeverity {
        case .safe:  return .primary
        case .amber: return .orange
        case .red:   return .red
        }
    }

    private var accessibilityValue: String {
        "App master gain \(gainText), today's exposure \(doseText), active profile balance \(balanceText)"
    }
}
