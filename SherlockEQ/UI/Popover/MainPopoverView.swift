import SwiftUI
import AppKit

/// The menu-bar popover. The 5-second surface: pick a profile, scrub the
/// compensation slider, toggle the tinnitus notch or Listening Comfort,
/// hit Reference Mode. Configuration (audiogram entry, parametric EQ,
/// per-processor comfort tuning, etc.) lives in the main window — opened
/// by the arrow button in the header.
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
            if let notice = audioState.userVisibleNotice {
                NoticeBannerView(notice: notice) {
                    audioState.dismissNotice()
                }
            }
            Divider()
            DoseBarView(
                percent: audioState.sessionDosePercent,
                remainingMinutes: audioState.remainingMinutes
            )
            PopoverLevelStrip(
                monitor: audioState.stereoMonitor,
                calibrationOffsetDBA: audioState.calibrationOffsetDBA
            )
            masterGainRow
            balanceRow
            Divider()
            ProfilePickerRow()
            CompensationSliderView()
            TinnitusNotchRow()
            ListeningComfortRow()
            ReferenceButton()
            Divider()
            quitRow
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
        HStack(spacing: 8) {
            Image(systemName: "waveform.and.magnifyingglass")
                .foregroundStyle(.tint)
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

            Button(action: openMainWindow) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("Open SherlockEQ")
        }
    }

    /// Quit the whole app from the popover. A menu-bar app has no window
    /// chrome to quit from when it's running headless (the main window may
    /// never have been opened), and the Dock icon is hidden in accessory
    /// mode — so without this the only exit is the AppKit menu's ⌘Q, which
    /// isn't discoverable from the popover. `NSApp.terminate` runs the normal
    /// termination path (same as the App menu's Quit item).
    @ViewBuilder private var quitRow: some View {
        HStack(spacing: 8) {
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit SherlockEQ", systemImage: "power")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit SherlockEQ (⌘Q)")
        }
    }

    // MARK: - Master gain + balance

    /// Same visual rhythm as `PopoverLevelStrip`: a 56 pt gutter label
    /// on the left so the row aligns with the level strip's "Level"
    /// label, then the slider, then the numeric readout, then a tiny
    /// recenter button. Master gain spans -60…+12 dB; reset returns
    /// to 0 dB.
    @ViewBuilder private var masterGainRow: some View {
        HStack(spacing: 8) {
            Text("Gain")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Slider(
                value: Binding(
                    get: { audioState.masterGainDB },
                    set: { audioState.masterGainDB = $0 }
                ),
                in: -60...12
            )
            .controlSize(.small)
            Text(formatGain(audioState.masterGainDB))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 56, alignment: .trailing)
            Button { audioState.masterGainDB = 0 } label: {
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
                    .frame(width: 80, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { profile.balance },
                        set: { newValue in
                            var updated = profile
                            updated.balance = newValue
                            try? profileStore.save(updated)
                        }
                    ),
                    in: -1...1
                )
                .controlSize(.small)
                Text(balanceLabel(profile.balance))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 56, alignment: .trailing)
                Button {
                    var updated = profile
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
