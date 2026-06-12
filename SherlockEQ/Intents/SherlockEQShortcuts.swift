import AppIntents

/// Surfaces a handful of SherlockEQ actions in Spotlight, the Shortcuts app's
/// gallery, and Siri without the user having to build a shortcut first. Every
/// intent is still independently usable as a Shortcuts action; these are just
/// the ones promoted with spoken phrases.
struct SherlockEQShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleReferenceModeIntent(),
            phrases: [
                "Toggle reference mode in \(.applicationName)",
                "Toggle \(.applicationName) reference mode",
                "Bypass \(.applicationName)",
            ],
            shortTitle: "Toggle Reference Mode",
            systemImageName: "waveform.slash"
        )
        AppShortcut(
            intent: ActivateProfileIntent(),
            phrases: [
                "Activate a profile in \(.applicationName)",
                "Switch \(.applicationName) profile",
            ],
            shortTitle: "Activate Profile",
            systemImageName: "person.crop.circle"
        )
        AppShortcut(
            intent: SetMasterGainIntent(),
            phrases: [
                "Set \(.applicationName) master gain",
            ],
            shortTitle: "Set Master Gain",
            systemImageName: "speaker.wave.2"
        )
        AppShortcut(
            intent: GetStatusIntent(),
            phrases: [
                "Get \(.applicationName) status",
                "What is \(.applicationName) doing",
            ],
            shortTitle: "Get Status",
            systemImageName: "info.circle"
        )
    }
}
