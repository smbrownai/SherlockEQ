import SwiftUI
import AppKit

/// The menu-bar popover. The 5-second surface: pick a profile, scrub the
/// compensation slider, toggle the tinnitus notch, hit Reference Mode.
/// Configuration (audiogram entry, parametric EQ, etc.) lives in the main
/// window — opened by the arrow button in the header.
struct MainPopoverView: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            DoseBarView(
                percent: audioState.sessionDosePercent,
                remainingMinutes: audioState.remainingMinutes
            )
            Divider()
            ProfilePickerRow()
            CompensationSliderView()
            TinnitusNotchRow()
            ReferenceButton()
        }
        .padding(14)
        .frame(width: 380)
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.and.magnifyingglass")
                .foregroundStyle(.tint)
            Text("AuditumEQ").font(.headline)
            Spacer()
            // Output device — read-only label for now; full picker comes when
            // we enumerate audio devices in a follow-on session.
            HStack(spacing: 4) {
                Image(systemName: deviceSymbol).font(.caption)
                Text(audioState.tap.currentOutputDeviceName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.secondary)

            Button(action: openMainWindow) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("Open AuditumEQ")
        }
    }

    /// Open (or focus) the main window. The app switches to `.accessory` on
    /// window close, so reopening has to flip back to `.regular` and
    /// re-activate to get the menu bar back. Calling `activate` in the same
    /// run-loop tick as `setActivationPolicy` is unreliable — AppKit hasn't
    /// finished registering the policy change, and the menu bar fails to
    /// redraw. Deferring activation to the next tick fixes it.
    private func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var deviceSymbol: String {
        let name = audioState.tap.currentOutputDeviceName.lowercased()
        if name.contains("airpod") || name.contains("bluetooth") { return "airpodspro" }
        if name.contains("display") || name.contains("monitor") { return "display" }
        if name.contains("headphone") { return "headphones" }
        return "speaker.wave.2"
    }
}
