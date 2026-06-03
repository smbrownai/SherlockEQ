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
                }
                .onDisappear {
                    // Window closed → back to menu-bar-only.
                    NSApp.setActivationPolicy(.accessory)
                }
        }

        MenuBarExtra("AuditumEQ", systemImage: "waveform.and.magnifyingglass") {
            MainPopoverView()
                .environmentObject(audioState)
                .environmentObject(profileStore)
        }
        .menuBarExtraStyle(.window)
    }
}
