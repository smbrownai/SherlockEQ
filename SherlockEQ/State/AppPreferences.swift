import Foundation
import AppKit
import Combine
import OSLog
import ServiceManagement
import SwiftUI

/// App-wide UI / shell preferences that aren't tied to the audio
/// pipeline — per-ear colors, dock visibility, launch-at-login, and
/// the global Reference-Mode shortcut. Each setting is persisted to
/// UserDefaults via its own `didSet` so flipping a toggle survives
/// relaunch. Some toggles also do real-world side effects (launch-
/// at-login register/unregister, dock policy flip) inside `didSet`.
///
/// Extracted from AudioState as part of the god-object split — these
/// have no coupling to audio beyond living in the same app, and view
/// surfaces that only care about UI prefs (Settings, MenuBarIcon,
/// AppDelegate's window-policy code) now have a clean dependency.
@MainActor
final class AppPreferences: ObservableObject {

    /// Per-ear colors — used everywhere a stereo curve / band / chart
    /// is drawn so users with colorblindness can dial in a palette
    /// they can distinguish. Persisted as #RRGGBB hex via UserDefaults.
    @Published var leftEarColor: Color = AppPreferences.loadColor(
        key: AppPreferences.leftEarColorKey,
        default: AppPreferences.defaultLeftEarColor
    ) {
        didSet { UserDefaults.standard.set(leftEarColor.hexString, forKey: Self.leftEarColorKey) }
    }
    @Published var rightEarColor: Color = AppPreferences.loadColor(
        key: AppPreferences.rightEarColorKey,
        default: AppPreferences.defaultRightEarColor
    ) {
        didSet { UserDefaults.standard.set(rightEarColor.hexString, forKey: Self.rightEarColorKey) }
    }

    static let defaultLeftEarColor: Color = .blue
    static let defaultRightEarColor: Color = .red

    /// When true, the app reverts to `.accessory` activation policy on
    /// window close (menu-bar-only, no Dock icon). When false, the Dock
    /// icon persists once the main window has been opened. Trade-off:
    /// `.accessory` keeps the app feeling like a menu-bar utility but
    /// macOS doesn't always redraw the system menu bar reliably on the
    /// `.accessory → .regular` swap; `.regular` permanently avoids that
    /// at the cost of a permanent Dock icon.
    @Published var hideFromDockEnabled: Bool = AppPreferences.loadBool(
        key: AppPreferences.hideFromDockKey,
        default: true
    ) {
        didSet {
            UserDefaults.standard.set(hideFromDockEnabled, forKey: Self.hideFromDockKey)
            // Absolute: the Dock icon follows this toggle alone, independent of
            // whether a window is open. On → `.accessory` (no Dock icon, but
            // the menu bar still appears when a window is active). Off →
            // `.regular` (Dock icon always). Applied immediately on change; the
            // launch-time value is applied by AppDelegate.
            NSApp.setActivationPolicy(hideFromDockEnabled ? .accessory : .regular)
        }
    }

    /// Mirrors `SMAppService.mainApp.status == .enabled`. Setting it
    /// calls `register()` / `unregister()`; if the OS rejects (Login Items
    /// permission denied or similar) the value reverts and the error is
    /// logged so the UI stays in sync with reality.
    @Published var launchAtLoginEnabled: Bool = (SMAppService.mainApp.status == .enabled) {
        didSet {
            guard launchAtLoginEnabled != oldValue else { return }
            do {
                if launchAtLoginEnabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                log.error("Launch-at-login toggle failed: \(error.localizedDescription, privacy: .public)")
                // Revert without re-triggering didSet (oldValue is the
                // pre-toggle truth; assign on next runloop).
                let revertTo = oldValue
                DispatchQueue.main.async { [weak self] in
                    self?.launchAtLoginEnabled = revertTo
                }
            }
        }
    }

    /// Global ⌘⇧B shortcut to toggle Reference Mode from any app. Off
    /// by default because system-wide hotkeys can collide with whatever's
    /// frontmost (Cmd-Shift-B is "Bookmarks bar" in some browsers); users
    /// who want it opt in from Settings. AppDelegate registers /
    /// unregisters the actual Carbon hotkey in response to this flag.
    @Published var globalReferenceShortcutEnabled: Bool = AppPreferences.loadBool(
        key: AppPreferences.globalReferenceShortcutKey,
        default: false
    ) {
        didSet {
            UserDefaults.standard.set(globalReferenceShortcutEnabled, forKey: Self.globalReferenceShortcutKey)
        }
    }

    /// Whether the diagnostic "Debug" entry shows in the main-window
    /// sidebar's App group. Off by default — it's a developer/support
    /// surface (counters, force-dose buttons, notification tests), not
    /// something most users need. Opt in from Settings when troubleshooting.
    @Published var showDebugInSidebar: Bool = AppPreferences.loadBool(
        key: AppPreferences.showDebugInSidebarKey,
        default: false
    ) {
        didSet {
            UserDefaults.standard.set(showDebugInSidebar, forKey: Self.showDebugInSidebarKey)
        }
    }

    /// Whether profile detail pages show the technical "Metadata" footer
    /// (created/modified timestamps + the profile's UUID). Off by default —
    /// it's a support/diagnostic surface, not something most users need. Opt
    /// in from Settings → Diagnostics.
    @Published var showProfileMetadata: Bool = AppPreferences.loadBool(
        key: AppPreferences.showProfileMetadataKey,
        default: false
    ) {
        didSet {
            UserDefaults.standard.set(showProfileMetadata, forKey: Self.showProfileMetadataKey)
        }
    }

    /// Whether the menu-bar popover shows its tone block: a small read-only EQ
    /// response curve plus the Bass / Mids / Treble quick-adjustment rows. On
    /// by default — together they answer "what is my EQ doing right now" and
    /// "make it a bit warmer" at a glance, which is the popover's job. Opt out
    /// for a shorter popover, or to keep the FFT pipeline idle while it's open
    /// (the curve is the only thing there that subscribes to the spectrum
    /// analyzers).
    ///
    /// One preference for both halves on purpose: the nudge buttons are
    /// relative, so the curve is the only place their effect is legible.
    /// Buttons without the curve would be a control with no readout.
    ///
    /// The stored key still says `showPopoverEQCurve` — renaming it would
    /// silently reset the preference for everyone who had already turned it
    /// off. Detailed editing stays on the Equalizer screen either way.
    @Published var showPopoverEQCurve: Bool = AppPreferences.loadBool(
        key: AppPreferences.showPopoverEQCurveKey,
        default: true
    ) {
        didSet {
            UserDefaults.standard.set(showPopoverEQCurve, forKey: Self.showPopoverEQCurveKey)
        }
    }

    /// Set once the first-launch onboarding wizard has been completed (or
    /// skipped). Gates whether `AppDelegate.bootstrap()` shows the wizard
    /// instead of immediately firing the system-audio + notification
    /// permission prompts cold. Defaults to false so a fresh install runs
    /// onboarding; flipping it back to false (or `defaults delete`) replays it.
    @Published var hasCompletedOnboarding: Bool = AppPreferences.loadBool(
        key: AppPreferences.hasCompletedOnboardingKey,
        default: false
    ) {
        didSet {
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: Self.hasCompletedOnboardingKey)
        }
    }

    private let log = Logger(subsystem: "com.shawnbrown.SherlockEQ", category: "AppPreferences")

    // MARK: - UserDefaults plumbing

    private static let leftEarColorKey = "sherlockeq.leftEarColorHex"
    private static let rightEarColorKey = "sherlockeq.rightEarColorHex"
    private static let hideFromDockKey = "sherlockeq.hideFromDock"
    private static let globalReferenceShortcutKey = "sherlockeq.globalReferenceShortcut"
    private static let showDebugInSidebarKey = "sherlockeq.showDebugInSidebar"
    private static let showProfileMetadataKey = "sherlockeq.showProfileMetadata"
    private static let showPopoverEQCurveKey = "sherlockeq.showPopoverEQCurve"
    private static let hasCompletedOnboardingKey = "sherlockeq.hasCompletedOnboarding"

    private static func loadBool(key: String, default defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }

    private static func loadColor(key: String, default defaultValue: Color) -> Color {
        guard let hex = UserDefaults.standard.string(forKey: key),
              let color = Color(hexString: hex) else { return defaultValue }
        return color
    }
}
