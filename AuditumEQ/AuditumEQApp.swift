import SwiftUI

@main
struct AuditumEQApp: App {
    @StateObject private var audioState = AudioState()
    @StateObject private var profileStore = ProfileStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audioState)
                .environmentObject(profileStore)
                .task {
                    profileStore.loadAll()
                    profileStore.seedDefaultsIfEmpty()
                }
        }
    }
}
