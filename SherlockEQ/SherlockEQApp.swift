import SwiftUI

@main
struct SherlockEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
        // Window-open commands live in SwiftUI's menu, not the hand-built
        // NSMenu in AppDelegate. SwiftUI owns the menu bar for a MenuBarExtra
        // app and re-asserts its own menu whenever it activates or shows a
        // window, so items poked into `NSApp.mainMenu` from AppKit lost the
        // race intermittently — the Window menu came up without "SherlockEQ"
        // and "Analog Control Unit". Declaring them here puts them in the menu
        // SwiftUI actually keeps, so they're always present.
        .commands {
            CommandGroup(after: .windowList) {
                Button("SherlockEQ") { appDelegate.showMainWindow() }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Analog Control Unit") { appDelegate.showAnalogControlUnit() }
                    .keyboardShortcut("1", modifiers: .command)
            }
        }
    }
}
