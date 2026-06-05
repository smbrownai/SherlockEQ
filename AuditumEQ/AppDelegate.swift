import AppKit
import SwiftUI

/// Owns the main NSWindow and the long-lived `AudioState` / `ProfileStore`
/// singletons. This replaces SwiftUI's `Window` scene + `openWindow(id:)`
/// path because that combination couldn't reliably redraw the system menu
/// bar on the `.accessory → .regular` swap — even `dispatch_async`'ing
/// the `NSApp.activate` after `setActivationPolicy` left the user doing
/// a Cmd-Tab dance to get the menu bar to show. Owning the NSWindow lets
/// us sequence policy change → runloop pump → activate → key+orderFront
/// deterministically, and lets us pre-create the window so activation
/// isn't racing window construction.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// SwiftUI's `@NSApplicationDelegateAdaptor` installs a proxy /
    /// wrapper as `NSApp.delegate` rather than our instance directly.
    /// Lifecycle methods still forward to us (so `applicationDidFinishLaunching`
    /// runs on this object), but `NSApp.delegate as? AppDelegate` returns
    /// nil from outside. This singleton handle lets the popover and any
    /// other UI surface call back into us without the cast.
    static private(set) weak var shared: AppDelegate?

    let audioState = AudioState()
    let profileStore = ProfileStore()

    private var mainWindow: NSWindow?
    private let mainWindowUndoManager = UndoManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // Start as a menu-bar-only app. Flips to `.regular` on first
        // `showMainWindow`; flips back on window close if the user has
        // `hideFromDockEnabled` set.
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        bootstrap()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu-bar app: closing the window must not quit.
        false
    }

    private func bootstrap() {
        profileStore.loadAll()
        profileStore.seedDefaultsIfEmpty()
        audioState.adoptDefaultProfileIfNeeded(from: profileStore)
        audioState.connect(profileStore: profileStore)
        Task {
            await NotificationManager.shared.requestAuthorization()
            await audioState.startAll()
        }
    }

    // MARK: - Window management

    /// Public entry point. Idempotent — safe to call from the popover's
    /// "open main window" button on every press; reuses the same NSWindow
    /// and just brings it forward.
    func showMainWindow() {
        if mainWindow == nil {
            mainWindow = createMainWindow()
        }
        guard let window = mainWindow else { return }

        // Sequence matters. The Cmd-Tab dance under SwiftUI's `Window`
        // scene was the policy change and the activate landing in the
        // same runloop tick, before AppKit's bookkeeping caught up. By
        // owning the window we can:
        //   1. Set the policy.
        //   2. Spin the runloop a moment so AppKit registers it.
        //   3. Activate the app — now the menu bar attaches correctly.
        //   4. Order our window front and make it key.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            // ~10 ms of runloop pumping is plenty for AppKit to process
            // the policy change without a perceptible delay.
            RunLoop.current.run(mode: .common, before: Date(timeIntervalSinceNow: 0.01))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func createMainWindow() -> NSWindow {
        let root = MainWindowView()
            .environmentObject(audioState)
            .environmentObject(profileStore)
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = "AuditumEQ"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = false
        window.setContentSize(NSSize(width: 1480, height: 820))
        window.minSize = NSSize(width: 1400, height: 740)
        window.setFrameAutosaveName("AuditumEQ.MainWindow")
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Visible on all Spaces is wrong for a main window; just default.
        window.center()
        return window
    }

    // MARK: - Main menu (AppKit)

    private func installMainMenu() {
        let mainMenu = NSMenu()
        mainMenu.addItem(makeAppMenuItem())
        mainMenu.addItem(makeEditMenuItem())
        mainMenu.addItem(makeAudioMenuItem())
        mainMenu.addItem(makeWindowMenuItem())
        NSApp.mainMenu = mainMenu
    }

    private func makeAppMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        menu.addItem(withTitle: "About \(appName)",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        let hide = NSMenuItem(title: "Hide \(appName)",
                              action: #selector(NSApplication.hide(_:)),
                              keyEquivalent: "h")
        menu.addItem(hide)
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(appName)",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    private func makeEditMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        // Undo/Redo dispatch via responder chain to the window's
        // UndoManager (provided by `windowWillReturnUndoManager`).
        menu.addItem(withTitle: "Undo",
                     action: Selector(("undo:")),
                     keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo",
                              action: Selector(("redo:")),
                              keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut",
                     action: #selector(NSText.cut(_:)),
                     keyEquivalent: "x")
        menu.addItem(withTitle: "Copy",
                     action: #selector(NSText.copy(_:)),
                     keyEquivalent: "c")
        menu.addItem(withTitle: "Paste",
                     action: #selector(NSText.paste(_:)),
                     keyEquivalent: "v")
        menu.addItem(withTitle: "Select All",
                     action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")

        item.submenu = menu
        return item
    }

    private func makeAudioMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Audio")
        let toggle = NSMenuItem(title: "Toggle Reference Mode",
                                action: #selector(toggleReferenceMode(_:)),
                                keyEquivalent: "b")
        toggle.target = self
        menu.addItem(toggle)
        item.submenu = menu
        return item
    }

    private func makeWindowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom",
                     action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        let show = NSMenuItem(title: "AuditumEQ",
                              action: #selector(showMainWindowFromMenu(_:)),
                              keyEquivalent: "0")
        show.target = self
        menu.addItem(show)
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }

    @objc private func toggleReferenceMode(_ sender: Any?) {
        audioState.referenceMode.toggle()
    }

    @objc private func showMainWindowFromMenu(_ sender: Any?) {
        showMainWindow()
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        // Mirror the old SwiftUI `.onDisappear` policy flip. With the
        // window-close trigger this fires reliably on every close.
        if audioState.hideFromDockEnabled {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        // SwiftUI's `@Environment(\.undoManager)` reads through the
        // hosting view's window. Without this delegate hook NSWindow
        // returns nil and `UndoManagerLink` can't wire `ProfileStore`
        // into the Edit-menu Undo / Redo path.
        mainWindowUndoManager
    }
}
