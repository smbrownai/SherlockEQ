import AppKit
import Carbon
import Combine
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
    let profileStore = ProfileStore(directory: ProfileStore.bootDirectory())
    /// Phase-1 / Phase-2 fetcher for the AutoEQ remote catalog. Single
    /// shared instance so the cached index + in-flight rate-limit
    /// backoff are consistent across every surface that opens the
    /// search view (popover-less for now, but the saved-list is also
    /// driven from here).
    let autoEQRemote = AutoEQRemoteService()
    let autoEQSavedProfiles = AutoEQSavedProfilesStore()

    /// Backs the `sherlockeq` command-line tool. Vends a CFMessagePort the CLI
    /// connects to; all commands run against `audioState` / `profileStore`, so
    /// the GUI reflects CLI changes live. See `CLIControlServer`.
    private var cliServer: CLIControlServer?

    private var mainWindow: NSWindow?
    private var analogWindow: NSWindow?
    private var helpWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private let mainWindowUndoManager = UndoManager()
    private let globalReferenceHotKey = GlobalHotKey()
    private var cancellables: Set<AnyCancellable> = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Multi-instance guard: a second SherlockEQ binary would install
        // its own global CATap. Each instance only excludes its own PID
        // from the system tap, so each would capture the other's
        // processed output → AVAudioEngine → tap, creating a feedback
        // loop. Detect an already-running instance and hand off to it.
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me.processIdentifier }
        if let existing = others.first {
            existing.activate()
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // Start as a menu-bar-only app. Flips to `.regular` on first
        // `showMainWindow`; flips back on window close if the user has
        // `hideFromDockEnabled` set.
        NSApp.setActivationPolicy(.accessory)
        // Let `HelpCenter.shared.open(topic:)` (called from menu items and
        // contextual `?` buttons anywhere in the app) bring the help window
        // forward without knowing anything about NSWindow. Window lifecycle
        // stays here; routing stays in HelpCenter.
        HelpCenter.shared.onShow = { [weak self] in self?.showHelpWindow() }
        bootstrap()
        // SwiftUI's scene system installs its own NSApp.mainMenu *after*
        // applicationDidFinishLaunching returns, wiping anything we set
        // here. Defer our install to the next runloop tick so ours wins.
        Task { @MainActor in installMainMenu() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Safety net: if anything else (a sub-window, an alert sheet, a
        // scene-restore cycle) reinstalls SwiftUI's default menu, restore
        // ours whenever the app comes forward.
        installMainMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu-bar app: closing the window must not quit.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        cliServer?.stop()
    }

    /// Stand up the CLI control port. The handler is a plain `(Data) -> Data`
    /// closure invoked on the main thread by the port's run-loop source, so we
    /// hop into main-actor isolation to reach `audioState` / `profileStore`.
    private func startCLIServer() {
        let handler = CLICommandHandler(audioState: audioState, profileStore: profileStore)
        let server = CLIControlServer { data in
            MainActor.assumeIsolated { handler.handle(data) }
        }
        server.start()
        cliServer = server
    }

    private func bootstrap() {
        profileStore.loadAll()
        profileStore.reconcileFactoryPresets()
        audioState.adoptDefaultProfileIfNeeded(from: profileStore)
        audioState.connect(profileStore: profileStore)
        startCLIServer()
        applyGlobalReferenceShortcut(enabled: audioState.preferences.globalReferenceShortcutEnabled)
        audioState.preferences.$globalReferenceShortcutEnabled
            .sink { [weak self] enabled in self?.applyGlobalReferenceShortcut(enabled: enabled) }
            .store(in: &cancellables)

        if audioState.preferences.hasCompletedOnboarding {
            // Returning launch: bring the tap up and reconcile the
            // notification grant exactly as before.
            requestNotificationsAndStartAudio()
        } else {
            // Fresh install: do NOT fire the system-audio + notification
            // prompts cold here. The onboarding wizard explains the
            // non-obvious System Audio Recording grant first, then triggers
            // the same work via `finishOnboarding` so the prompts arrive
            // *after* the explanation rather than as the app's opening act.
            showOnboardingWindow()
        }
    }

    /// Request notification authorization (no-op if already answered) and
    /// bring up the audio pipeline. Shared by the returning-launch path and
    /// by onboarding completion so the order of operations is identical.
    private func requestNotificationsAndStartAudio() {
        Task {
            await NotificationManager.shared.requestAuthorization()
            // If the user denied notifications (either just now or in a
            // prior session), surface that as a one-shot warning. Without
            // it the user has no idea they've lost the safe-listening
            // alerts until they happen to dose past amber later.
            audioState.noticeCenter.warnIfNotificationsDenied(
                status: NotificationManager.shared.authorizationStatus
            )
            await audioState.startAll()
        }
    }

    private func applyGlobalReferenceShortcut(enabled: Bool) {
        if enabled {
            // ⌘⇧B — same key as the local Cmd+B from the AppKit Audio menu,
            // with Shift added to make the global form less collision-prone
            // with frontmost-app shortcuts.
            globalReferenceHotKey.register(
                keyCode: kVK_ANSI_B,
                modifiers: cmdKey | shiftKey
            ) { [weak self] in
                self?.audioState.referenceMode.toggle()
            }
        } else {
            globalReferenceHotKey.unregister()
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
        // `NSApp.activate(ignoringOtherApps:)` is deprecated in macOS 14
        // and the system can silently drop the request — the window
        // appears but the menu bar stays in its inactive (greyed) state
        // because the OS doesn't think we're truly frontmost.
        // `NSRunningApplication.current.activate(options:)` is the
        // forceful replacement that brings every window forward and
        // properly transfers menu-bar focus.
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.makeKeyAndOrderFront(nil)
    }

    private func createMainWindow() -> NSWindow {
        let root = MainWindowView()
            .environmentObject(audioState)
            .environmentObject(profileStore)
            .environmentObject(autoEQRemote)
            .environmentObject(autoEQSavedProfiles)
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = "SherlockEQ"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = false
        window.setContentSize(NSSize(width: 1400, height: 800))
        window.minSize = NSSize(width: 1366, height: 756)
        window.setFrameAutosaveName("SherlockEQ.MainWindow")
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Visible on all Spaces is wrong for a main window; just default.
        window.center()
        return window
    }

    // MARK: - Analog Control Unit (optional alternate surface)

    /// Open (or focus) the Analog Control Unit — a fixed-size vintage
    /// front panel that's a pure view over existing gain / balance /
    /// simple-EQ state. Same activation dance as `showMainWindow` so the
    /// menu bar attaches correctly when the app was menu-bar-only.
    func showAnalogControlUnit() {
        // First open (window absent or currently closed) enters analog mode;
        // re-triggering the menu while it's up just refocuses.
        let firstOpen = !(analogWindow?.isVisible ?? false)
        if analogWindow == nil {
            analogWindow = createAnalogControlWindow()
        }
        guard let window = analogWindow else { return }
        if firstOpen { audioState.beginAnalogOverride() }

        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            RunLoop.current.run(mode: .common, before: Date(timeIntervalSinceNow: 0.01))
        }
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.makeKeyAndOrderFront(nil)
    }

    private func createAnalogControlWindow() -> NSWindow {
        let root = AnalogControlUnitView()
            .environmentObject(audioState)
            .environmentObject(profileStore)
            .environmentObject(autoEQRemote)
            .environmentObject(autoEQSavedProfiles)
        let hosting = NSHostingController(rootView: root)

        // Fixed width; height is owned by the spectrum-expanded flag (collapsed
        // 700×400, expanded 700×600). The user can't free-resize — no
        // `.resizable`. `.fullSizeContentView` + hidden title lets the brushed
        // metal run edge-to-edge behind the traffic lights.
        let window = NSWindow(contentViewController: hosting)
        window.title = "Analog Control Unit"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        let expanded = UserDefaults.standard.bool(forKey: AnalogSpectrumConfig.expandedKey)
        let initialHeight = expanded ? AnalogSpectrumConfig.expandedHeight : AnalogSpectrumConfig.collapsedHeight
        window.setContentSize(NSSize(width: 700, height: initialHeight))
        window.setFrameAutosaveName("SherlockEQ.AnalogControlUnit")
        // Autosave may restore a stale size; the expanded flag owns the
        // height. Re-assert width + height, anchored to a fixed top edge.
        var frame = window.frame
        let top = frame.maxY
        frame.size = NSSize(width: 700, height: initialHeight)
        frame.origin.y = top - initialHeight
        window.setFrame(frame, display: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    /// Grow / shrink the Analog Control Unit window to reveal or hide the
    /// spectrum panel. Anchored to a fixed top edge so it grows downward.
    func setAnalogControlUnitExpanded(_ expanded: Bool) {
        guard let window = analogWindow else { return }
        let height = expanded ? AnalogSpectrumConfig.expandedHeight : AnalogSpectrumConfig.collapsedHeight
        var frame = window.frame
        let top = frame.maxY
        frame.size = NSSize(width: 700, height: height)
        frame.origin.y = top - height
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: - Help window

    /// Open (or focus) the SherlockEQ Help window. Idempotent — reuses the
    /// one window and brings it forward, navigating to whatever article
    /// `HelpCenter` currently points at. Same `.accessory → .regular`
    /// activation dance as the other windows so the menu bar attaches when
    /// the app was menu-bar-only (e.g. help opened from a popover `?` button).
    func showHelpWindow() {
        if helpWindow == nil {
            helpWindow = createHelpWindow()
        }
        guard let window = helpWindow else { return }

        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            RunLoop.current.run(mode: .common, before: Date(timeIntervalSinceNow: 0.01))
        }
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.makeKeyAndOrderFront(nil)
    }

    private func createHelpWindow() -> NSWindow {
        let root = HelpWindowView()
            .environmentObject(HelpCenter.shared)
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = "SherlockEQ Help"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1040, height: 680))
        window.minSize = NSSize(width: 820, height: 560)
        // Persist size/position so the help window reopens where the user left it.
        window.setFrameAutosaveName("SherlockEQ.HelpWindow")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    // MARK: - Onboarding window

    /// Open (or focus) the first-launch onboarding wizard. Public so the
    /// Debug screen's "Replay now" button can re-run it on demand. Same
    /// `.accessory → .regular` activation dance as the other windows.
    func showOnboardingWindow() {
        if onboardingWindow == nil {
            onboardingWindow = createOnboardingWindow()
        }
        guard let window = onboardingWindow else { return }

        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            RunLoop.current.run(mode: .common, before: Date(timeIntervalSinceNow: 0.01))
        }
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.makeKeyAndOrderFront(nil)
    }

    private func createOnboardingWindow() -> NSWindow {
        let root = OnboardingView(onFinish: { [weak self] section in
            self?.finishOnboarding(deepLink: section)
        })
        .environmentObject(audioState)
        .environmentObject(profileStore)
        .environmentObject(autoEQRemote)
        .environmentObject(autoEQSavedProfiles)
        let hosting = NSHostingController(rootView: root)

        // Fixed-size welcome panel (the SwiftUI root is a fixed 560×640).
        // No `.resizable` — the content owns the size. Not in the frame-
        // autosave set: it should always open centered, not wherever a
        // prior run left it.
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to SherlockEQ"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 560, height: 640))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    /// Completion handler handed to `OnboardingView`. Flips the gate flag,
    /// runs the deferred permission/start work, optionally deep-links the
    /// main window to a section, then closes the wizard. Closing routes
    /// through `windowWillClose`, which is a no-op for the start work now
    /// that the flag is already set.
    private func finishOnboarding(deepLink section: SidebarSection?) {
        audioState.preferences.hasCompletedOnboarding = true
        if let section {
            // Set the intent before opening so the main window's `onAppear`
            // catches it on first construction.
            audioState.pendingMainSection = section
            showMainWindow()
        }
        onboardingWindow?.close()
        requestNotificationsAndStartAudio()
    }

    @objc private func openHelpHome(_ sender: Any?) {
        HelpCenter.shared.open(topic: .home)
    }

    @objc private func openHelpTopic(_ sender: NSMenuItem) {
        guard let slug = sender.representedObject as? String else { return }
        HelpCenter.shared.open(slug: slug)
    }

    // MARK: - Main menu (AppKit)

    private func installMainMenu() {
        let mainMenu = NSMenu()
        mainMenu.addItem(makeAppMenuItem())
        mainMenu.addItem(makeFileMenuItem())
        mainMenu.addItem(makeEditMenuItem())
        mainMenu.addItem(makeAudioMenuItem())
        mainMenu.addItem(makeWindowMenuItem())
        mainMenu.addItem(makeHelpMenuItem())
        NSApp.mainMenu = mainMenu
    }

    /// Standard macOS Help menu. The first item opens the help window at
    /// its home article; the rest jump straight to a topic. Assigning
    /// `NSApp.helpMenu` gives us the system-provided Spotlight-for-Help
    /// search field at the top of the menu for free, and positions the
    /// menu correctly as the trailing menu.
    private func makeHelpMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Help")

        // Primary entry — opens (or focuses) the window at the home page.
        let main = NSMenuItem(title: "SherlockEQ Help",
                              action: #selector(openHelpHome(_:)),
                              keyEquivalent: "?")
        main.target = self
        menu.addItem(main)
        menu.addItem(.separator())

        // One item per documented topic, in the spec's order. Each carries
        // its slug as `representedObject`, so a single action handles them all.
        let topics: [HelpTopic] = [
            .gettingStarted, .featureGuide, .understandingEQ,
            .audiogramProfiles, .tinnitusToneMatching, .headphoneCorrection,
            .vuMeters, .analogControlUnit, .safetyLimits, .privacy,
            .troubleshooting, .keyboardShortcuts, .commandLineTool, .releaseNotes,
        ]
        for topic in topics {
            let title = HelpCenter.shared.library.title(for: topic.slug)
            let mi = NSMenuItem(title: title,
                                action: #selector(openHelpTopic(_:)),
                                keyEquivalent: "")
            mi.target = self
            mi.representedObject = topic.slug
            menu.addItem(mi)
        }

        item.submenu = menu
        NSApp.helpMenu = menu
        return item
    }

    private func makeFileMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "Close Window",
                     action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
        item.submenu = menu
        return item
    }

    private func makeAppMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        menu.addItem(withTitle: "About \(appName)",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")

        if UpdaterController.shared.hasUpdater {
            let check = NSMenuItem(title: "Check for Updates…",
                                   action: #selector(UpdaterController.checkForUpdates(_:)),
                                   keyEquivalent: "")
            check.target = UpdaterController.shared
            menu.addItem(check)
        }

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
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
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
        let item = NSMenuItem(title: "Audio", action: nil, keyEquivalent: "")
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
        let item = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom",
                     action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        let show = NSMenuItem(title: "SherlockEQ",
                              action: #selector(showMainWindowFromMenu(_:)),
                              keyEquivalent: "0")
        show.target = self
        menu.addItem(show)
        let analog = NSMenuItem(title: "Analog Control Unit",
                                action: #selector(showAnalogControlUnitFromMenu(_:)),
                                keyEquivalent: "")
        analog.target = self
        menu.addItem(analog)
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

    @objc private func showAnalogControlUnitFromMenu(_ sender: Any?) {
        showAnalogControlUnit()
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        // Leaving the Analog Control Unit restores the real active profile.
        if closing === analogWindow {
            audioState.endAnalogOverride()
        }
        // Closing the onboarding window via the red button counts as a
        // skip: honor it like Finish so the wizard doesn't reappear next
        // launch and the audio pipeline still comes up. The Finish/jump
        // path sets the flag first, so this is a no-op there.
        if closing === onboardingWindow {
            if !audioState.preferences.hasCompletedOnboarding {
                audioState.preferences.hasCompletedOnboarding = true
                requestNotificationsAndStartAudio()
            }
            onboardingWindow = nil
        }
        // Mirror the old SwiftUI `.onDisappear` policy flip. With the
        // window-close trigger this fires reliably on every close. Only
        // drop back to accessory when the *last* managed window closes —
        // otherwise closing the Analog Control Unit while the main window
        // is open (or vice versa) would wrongly hide the Dock icon.
        guard audioState.hideFromDockEnabled else { return }
        let stillOpen = [mainWindow, analogWindow, helpWindow, onboardingWindow]
            .compactMap { $0 }
            .contains { $0 !== closing && $0.isVisible }
        if !stillOpen {
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
