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
            // Turning the toggle off (show in Dock) takes effect right
            // away. Turning it on only kicks in on next window close.
            if !hideFromDockEnabled {
                NSApp.setActivationPolicy(.regular)
            }
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

    private let log = Logger(subsystem: "com.shawnbrown.AuditumEQ", category: "AppPreferences")

    // MARK: - UserDefaults plumbing

    private static let leftEarColorKey = "auditumeq.leftEarColorHex"
    private static let rightEarColorKey = "auditumeq.rightEarColorHex"
    private static let hideFromDockKey = "auditumeq.hideFromDock"
    private static let globalReferenceShortcutKey = "auditumeq.globalReferenceShortcut"

    private static func loadBool(key: String, default defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }

    private static func loadColor(key: String, default defaultValue: Color) -> Color {
        guard let hex = UserDefaults.standard.string(forKey: key),
              let color = Color(hexString: hex) else { return defaultValue }
        return color
    }
}
