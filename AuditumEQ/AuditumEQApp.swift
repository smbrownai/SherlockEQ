import SwiftUI

@main
struct AuditumEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MainPopoverView()
                .environmentObject(appDelegate.audioState)
                .environmentObject(appDelegate.profileStore)
        } label: {
            MenuBarIcon(audioState: appDelegate.audioState)
        }
        .menuBarExtraStyle(.window)
    }
}
