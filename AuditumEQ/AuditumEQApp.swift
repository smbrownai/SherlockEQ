import SwiftUI

@main
struct AuditumEQApp: App {
    @StateObject private var audioState = AudioState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audioState)
        }
    }
}
