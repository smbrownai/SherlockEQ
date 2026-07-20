import SwiftUI
import AppKit
import Combine

/// The menu-bar popover — a status dashboard and remote for *today's
/// listening session*, not a compressed copy of the app. Top to bottom: is
/// SherlockEQ running and what is it processing (header); who's active and
/// the one-tap bypass (Profile, Reference Mode); how loud is it and how much
/// exposure has accumulated, plus the two controls worth a quick nudge
/// (Output level, Exposure, Gain, Balance); and finally what's configured,
/// always visible and always a link, never a switch (Processing details).
/// Configuring *how* SherlockEQ works stays in the main window.
struct MainPopoverView: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore
    /// Closes the `.window`-style `MenuBarExtra` popover. Used when handing
    /// off to the main window so the popover doesn't linger behind it.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            // Surface the same notice the main window's banner would
            // show. Users who live in the popover (the whole point of
            // a menu-bar app) need to see save failures, tap-permission
            // denials, and the safety warnings here too. Both mounts
            // read from the same `AudioState.noticeCenter`, so dismiss
            // from either clears both.
            if let notice = audioState.noticeCenter.userVisibleNotice {
                NoticeBannerView(notice: notice) {
                    audioState.dismissNotice()
                }
            }
            Divider()
            // "Who, and is it actually running" — the profile you're on and
            // the one-tap bypass — before any readout, because they're the
            // controls worth reaching without opening a window at all.
            ProfilePickerRow()
            ReferenceButton()
            // Headphone-correction device mismatch (spec §7) — tied to the
            // profile/device pairing just above it, so it surfaces right
            // where that context is already on screen.
            AutoEQMismatchRow(compact: true)
            Divider()
            // Live readouts: what's actually happening right now, and the
            // controls worth a quick nudge. No scope badges — the popover's
            // job is a glance, not a legend.
            PopoverLiveStatusRows(tracker: audioState.safeListening)
            masterGainRow
            balanceRow
            toneBlock
            Divider()
            processingDetails
            Divider()
            footerActions
        }
        .padding(14)
        .frame(width: 380)
        .task {
            // Auto-start the tap the first time the popover opens, so
            // users don't have to dig into Debug. No-op if the main
            // window already started it.
            await audioState.startAll()
        }
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("SherlockEQ").font(.headline)
                Spacer()
                // Output device — read-only label for now; full picker comes when
                // we enumerate audio devices in a follow-on session.
                HStack(spacing: 4) {
                    Image(systemName: deviceSymbol).font(.callout)
                    Text(audioState.tap.currentOutputDeviceName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(.secondary)
            }
            // "Is it actually doing anything, and to what?" is the first
            // question the popover exists to answer — so it's answered before
            // any control.
            processingStatus
        }
    }

    /// Reference Mode is called out here because it's the one state where the
    /// app is running, a profile is active, and yet nothing is being applied —
    /// the exact case where a bare "Processing <profile>" would be a lie.
    @ViewBuilder private var processingStatus: some View {
        if audioState.eqChain.referenceMode {
            statusLine("Reference Mode — processing bypassed",
                       symbol: "circle.fill", tint: .red)
        } else if let profile = audioState.activeProfile(in: profileStore) {
            statusLine("Processing \(profile.name)",
                       symbol: "waveform", tint: .green)
        } else {
            statusLine("No active profile — audio passing through",
                       symbol: "waveform.slash", tint: .secondary)
        }
    }

    private func statusLine(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
    }

    /// Hearing adjustment / Adaptive Comfort / Tinnitus notch — always
    /// visible, never a chevron-to-expand. These are status-and-link rows,
    /// not controls: each one reports what's configured and hands off to the
    /// main window to change it, so there's nothing here that risks a
    /// surprise edit if a user just glances past it while it's collapsed —
    /// the old failure mode a DisclosureGroup invited. See
    /// `HearingAdjustmentRow`'s doc comment for why the popover reports
    /// instead of edits.
    ///
    /// Safe Listening deliberately has no row here: it's the same subject as
    /// the live Exposure readout above (both were rendering "Not calibrated"),
    /// so that row carries the state and doubles as the link.
    /// No section heading: the three rows are self-describing ("Hearing
    /// adjustment", "Adaptive Comfort", "Tinnitus notch") and the divider
    /// above already separates them, so a "Processing details" label was
    /// naming a group that names itself.
    @ViewBuilder private var processingDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            HearingAdjustmentRow()
            ListeningComfortRow()
            TinnitusNotchRow()
        }
    }

    /// Both footer actions on one line: "Open Main Window" leading, "Quit"
    /// trailing. They were stacked as two full-width rows, which gave two
    /// infrequent actions as much vertical weight as the live readouts above.
    /// Pushing Quit to the trailing edge also separates it from the benign
    /// action — they're no longer adjacent targets in the same column.
    ///
    /// Quit matters here because a menu-bar app running headless has no
    /// window chrome to quit from and hides its Dock icon in accessory mode,
    /// so without this the only exit is the AppKit menu's ⌘Q, which isn't
    /// discoverable from the popover. `NSApp.terminate` runs the normal
    /// termination path (same as the App menu's Quit item).
    @ViewBuilder private var footerActions: some View {
        HStack(spacing: 8) {
            footerButton("Open Main Window", systemImage: "macwindow",
                         help: "Open the main SherlockEQ window",
                         action: openMainWindow)
            Spacer(minLength: 8)
            footerButton("Quit", systemImage: "power",
                         help: "Quit SherlockEQ (⌘Q)") {
                NSApp.terminate(nil)
            }
        }
    }

    /// Shared style for the two footer actions: icon + label, primary text
    /// colour (no accent / secondary tinting), hit area bounded to the
    /// button's own content now that the two sit side by side — a
    /// full-width `contentShape` would make them overlap.
    @ViewBuilder private func footerButton(_ title: String, systemImage: String,
                                           help: String,
                                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.callout)
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Tone block

    /// The read-only EQ curve and the three quick-adjustment rows, as one
    /// unit: the picture and the controls that change it.
    ///
    /// Both hang off the same preference. Showing the nudge buttons without
    /// the curve would leave the popover's only tone controls with nowhere to
    /// show their effect — the whole reason these are relative nudges rather
    /// than faders is that the curve is where the state is legible. So the
    /// preference governs the block, not just the drawing.
    ///
    /// Separated by a divider on both sides and given no heading: the curve
    /// and the row labels already say what this is.
    @ViewBuilder private var toneBlock: some View {
        if audioState.preferences.showPopoverEQCurve {
            Divider()
            PopoverEQCurve()
            // Stepped tone nudges that move the twelve graphic bands directly.
            // Not filters, and not faders: the Equalizer stays the single
            // source of truth, and the popover claims no authoritative
            // "Bass: +2 dB" for a curve that can't have one. See `ToneMacro`.
            PopoverQuickAdjustRows()
        }
    }

    // MARK: - Master gain + balance

    /// Same visual rhythm as `PopoverLevelStrip`: a 108 pt gutter label on
    /// the left so every row aligns, then the slider, the numeric readout,
    /// and a tiny reset button. Master gain spans -60…+12 dB; reset returns
    /// to 0 dB. No scope badge — the popover is a glance surface, and scope
    /// disambiguation (app vs. profile vs. today) belongs on the main
    /// window, where there's room to explain it rather than abbreviate it.
    @ViewBuilder private var masterGainRow: some View {
        HStack(spacing: 8) {
            Text("Gain")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)
            Slider(
                value: Binding(
                    get: { audioState.engineParameters.masterGainDB },
                    set: { audioState.engineParameters.masterGainDB = $0 }
                ),
                in: -60...12
            )
            .controlSize(.small)
            // The visible "Gain" text is a sibling, not this control's label —
            // without this VO announces only a bare value (audit UX-03).
            .accessibilityLabel("Master gain")
            Text(formatGain(audioState.engineParameters.masterGainDB))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 56, alignment: .trailing)
            Button { audioState.engineParameters.masterGainDB = 0 } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help("Reset master gain to 0 dB")
        }
    }

    /// Balance lives on the active profile, so we only show this row
    /// when a profile is loaded. Saving through `ProfileStore` triggers
    /// `applyActiveProfile` via the deferred Combine sink in
    /// `AudioState` — see `published-willset-stale-read.md`.
    @ViewBuilder private var balanceRow: some View {
        if let profile = audioState.activeProfile(in: profileStore) {
            HStack(spacing: 8) {
                Text("Balance")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 108, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { profile.balance },
                        set: { newValue in
                            // Live copy, not the body-render snapshot — saving
                            // the stale whole struct would clobber concurrent
                            // edits from the main window (audit CX-05).
                            var updated = profileStore.profiles.first { $0.id == profile.id } ?? profile
                            updated.balance = newValue
                            try? profileStore.save(updated)
                        }
                    ),
                    in: -1...1
                )
                .controlSize(.small)
                .accessibilityLabel("Balance")
                Text(balanceLabel(profile.balance))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 56, alignment: .trailing)
                Button {
                    var updated = profileStore.profiles.first { $0.id == profile.id } ?? profile
                    updated.balance = 0
                    try? profileStore.save(updated)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("Recenter balance")
            }
        }
    }

    private func formatGain(_ dB: Double) -> String {
        let abs = Swift.abs(dB)
        if abs < 0.05 {
            return String(localized: "0 dB", comment: "Master-gain readout when at unity (zero)")
        }
        // Number formatting (decimal separator, sign glyph) here still
        // uses ASCII via String(format:). Replacing with FormatStyle-based
        // formatting is the next pass.
        return String(format: "%@%.1f dB", dB > 0 ? "+" : "−", abs)
    }

    private func balanceLabel(_ b: Double) -> String {
        if abs(b) < 0.005 {
            return String(localized: "Center", comment: "Balance label when centred")
        }
        let pct = Int((abs(b) * 100).rounded())
        // "L" / "R" are channel abbreviations; some locales may prefer
        // localised forms. Placeholder \(pct) is the absolute % off-centre.
        return b < 0
            ? String(localized: "L \(pct)%", comment: "Balance label, panned left")
            : String(localized: "R \(pct)%", comment: "Balance label, panned right")
    }

    /// Open (or focus) the main window. Handed off to `AppDelegate`, which
    /// owns the NSWindow and sequences the `.accessory → .regular` policy
    /// flip + activation deterministically — see `AppDelegate.showMainWindow`.
    private func openMainWindow() {
        // Close the popover first — opening/activating the main window
        // doesn't dismiss the `.window`-style MenuBarExtra on its own, so
        // without this it lingers in front of (or beside) the window.
        dismiss()
        // SwiftUI's `@NSApplicationDelegateAdaptor` proxies `NSApp.delegate`,
        // so casting it back to `AppDelegate` returns nil. Reach the real
        // instance via the singleton handle.
        AppDelegate.shared?.showMainWindow()
    }

    private var deviceSymbol: String {
        let name = audioState.tap.currentOutputDeviceName.lowercased()
        if name.contains("airpod") || name.contains("bluetooth") { return "airpodspro" }
        if name.contains("display") || name.contains("monitor") { return "display" }
        if name.contains("headphone") { return "headphones" }
        return "speaker.wave.2"
    }
}

/// Output-level + exposure rows, subscribed to the tracker at a ≤1 Hz tick.
///
/// The parent used to compute these values from AudioState in its own body —
/// but SwiftUI doesn't observe a nested ObservableObject reached through a
/// property, so those reads refreshed only when AudioState published, and its
/// throttled mirror goes quiet entirely once the dose pins at the 1.0 cap
/// (equality guards see no change). Observing the tracker raw instead would
/// rebuild these Texts at ~10 Hz — the sub-pixel re-rasterization twitch the
/// mirror's throttle was added to prevent. So: the tracker's own
/// objectWillChange, throttled to 1 Hz, un-gated. The meters inside
/// `PopoverLevelStrip` stay live independently via their own StereoMonitor
/// subscription; only the row-level state (waiting-gate, dose values) ticks
/// at 1 Hz.
private struct PopoverLiveStatusRows: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss
    let tracker: SafeListeningTracker

    /// Bumped by the throttled subscription; `body` reads it so each tick
    /// invalidates the view even though no stored property changed.
    @State private var tick = 0

    var body: some View {
        let _ = tick   // tick dependency — see property comment
        Group {
            PopoverLevelStrip(
                monitor: audioState.stereoMonitor,
                // Effective (volume-tracked) offset so the zone boundaries
                // reflect at-ear level, not calibration-time level.
                calibrationOffsetDBA: audioState.effectiveCalibrationOffsetDBA,
                isReceivingAudio: tracker.currentLevelDBA >= ExposureStatus.audioFloorDBA
            )
            // Output level and exposure read as one pair — what's coming out
            // now, and what it's cost today. The EQ curve used to sit between
            // them; it now lives with the tone controls it belongs to.
            DoseBarView(
                percent: tracker.sessionDose,
                status: ExposureStatus.resolve(sessionDose: tracker.sessionDose,
                                               levelDBA: tracker.currentLevelDBA,
                                               hasCalibration: audioState.hasUserCalibration),
                severity: tracker.doseSeverity,
                remainingMinutes: tracker.remainingMinutes,
                // This row is also the way into Safe Listening — the separate
                // status row for it duplicated this row's calibration state.
                onOpen: openSafeListening,
                limitDB: audioState.activeProfile(in: profileStore)?.safeListeningCeilingDB
            )
        }
        .onReceive(tracker.objectWillChange
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)) { _ in
            tick &+= 1
        }
    }

    private func openSafeListening() {
        audioState.pendingMainSection = .safeListening
        dismiss()
        AppDelegate.shared?.showMainWindow()
    }
}
