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
    }
}
