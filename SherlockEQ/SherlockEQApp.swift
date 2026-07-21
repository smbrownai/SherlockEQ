import SwiftUI
import AppKit

@main
struct SherlockEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Help topics in the Help menu, in the spec's order. Mirrors the list the
    /// hand-built AppKit menu carried before the menu moved to SwiftUI.
    private static let helpTopics: [HelpTopic] = [
        .gettingStarted, .featureGuide, .understandingEQ,
        .audiogramProfiles, .tinnitusToneMatching, .headphoneCorrection,
        .vuMeters, .analogControlUnit, .safetyLimits, .privacy,
        .troubleshooting, .keyboardShortcuts, .commandLineTool, .releaseNotes,
    ]

    var body: some Scene {
        MenuBarExtra {
            MainPopoverView()
                .environmentObject(appDelegate.audioState)
                .environmentObject(appDelegate.audioState.preferences)
                .environmentObject(appDelegate.profileStore)
                .environmentObject(appDelegate.autoEQRemote)
                .environmentObject(appDelegate.autoEQSavedProfiles)
        } label: {
            MenuBarIcon(audioState: appDelegate.audioState)
        }
        .menuBarExtraStyle(.window)
        // The whole main menu lives here, in SwiftUI's `.commands`, not in a
        // hand-built NSMenu poked into `NSApp.mainMenu` from AppKit.
        //
        // For a MenuBarExtra app SwiftUI owns the menu bar and re-asserts its
        // own menu on launch, activation, and window show. Reassigning
        // `NSApp.mainMenu` from AppKit was a race SwiftUI won intermittently —
        // the menu came up as SwiftUI's default with our Audio menu and window
        // items missing, or (mid-activation) not redrawing on the system bar at
        // all. Declaring commands here puts them in the menu SwiftUI keeps, so
        // they're always present. See the AppDelegate note where the old NSMenu
        // builders used to live.
        //
        // Not re-declared here, because SwiftUI's baseline already provides
        // them and they route correctly: Edit (Cut/Copy/Paste/Undo/Redo — Undo
        // reaches the window's UndoManager via `windowWillReturnUndoManager`,
        // unchanged), and the standard Window items (Minimize/Zoom/Close).
        .commands {
            // App menu: custom About panel + Check for Updates, replacing
            // SwiftUI's stock "About" item.
            CommandGroup(replacing: .appInfo) {
                Button("About SherlockEQ") { appDelegate.showAboutPanel() }
                if UpdaterController.shared.hasUpdater {
                    Button("Check for Updates…") {
                        UpdaterController.shared.checkForUpdates(nil)
                    }
                }
            }

            // Audio menu — Reference Mode is the one global audio command that
            // belongs in the menu bar (⌘B works whenever the window is key; the
            // separate global hotkey covers the background case).
            CommandMenu("Audio") {
                Button("Toggle Reference Mode") {
                    appDelegate.audioState.eqChain.referenceMode.toggle()
                }
                .keyboardShortcut("b", modifiers: .command)
            }

            // Window: open/focus the two primary windows. `after: .windowList`
            // places them below the standard window entries.
            CommandGroup(after: .windowList) {
                Button("SherlockEQ") { appDelegate.showMainWindow() }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Analog Control Unit") { appDelegate.showAnalogControlUnit() }
                    .keyboardShortcut("1", modifiers: .command)
            }

            // Help: our own home entry plus one item per documented topic,
            // replacing SwiftUI's stock single Help item.
            CommandGroup(replacing: .help) {
                Button("SherlockEQ Help") { HelpCenter.shared.open() }
                    .keyboardShortcut("?", modifiers: .command)
                Divider()
                ForEach(Self.helpTopics, id: \.self) { topic in
                    Button(HelpCenter.shared.library.title(for: topic.slug)) {
                        HelpCenter.shared.open(topic: topic)
                    }
                }
            }
        }
    }
}
