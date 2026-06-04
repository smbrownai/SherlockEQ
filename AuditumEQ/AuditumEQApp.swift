import SwiftUI
import AppKit

@main
struct AuditumEQApp: App {
    @StateObject private var audioState = AudioState()
    @StateObject private var profileStore = ProfileStore()

    var body: some Scene {
        Window("AuditumEQ", id: "main") {
            MainWindowView()
                .environmentObject(audioState)
                .environmentObject(profileStore)
                .task {
                    profileStore.loadAll()
                    profileStore.seedDefaultsIfEmpty()
                    audioState.adoptDefaultProfileIfNeeded(from: profileStore)
                    audioState.connect(profileStore: profileStore)
                    await NotificationManager.shared.requestAuthorization()
                    // Auto-start the tap on first window-open so the user
                    // doesn't have to find the Debug → Start button. No-op
                    // if the tap is already running (popover may have
                    // started it first).
                    await audioState.startAll()
                }
                .onDisappear {
                    // Window closed → back to menu-bar-only, unless the
                    // user has opted to keep the Dock icon visible.
                    if audioState.hideFromDockEnabled {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
        }
        .commands {
            CommandMenu("Audio") {
                Button(audioState.referenceMode ? "Disable Reference Mode" : "Enable Reference Mode") {
                    audioState.referenceMode.toggle()
                }
                .keyboardShortcut("b", modifiers: .command)
            }
        }

        MenuBarExtra {
            MainPopoverView()
                .environmentObject(audioState)
                .environmentObject(profileStore)
        } label: {
            MenuBarIcon(audioState: audioState)
        }
        .menuBarExtraStyle(.window)
    }
}
