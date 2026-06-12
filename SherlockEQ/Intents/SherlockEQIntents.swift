import AppIntents
import Foundation

// MARK: - Shared helpers

/// Format a decibel / scalar value for spoken + written intent dialog.
private func formatDB(_ value: Double) -> String {
    String(format: "%.1f", value)
}

/// Reference-mode target for the "Set Reference Mode" action.
enum ReferenceModeState: String, AppEnum {
    case on
    case off

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Reference Mode State")
    }
    static var caseDisplayRepresentations: [ReferenceModeState: DisplayRepresentation] {
        [.on: "On", .off: "Off"]
    }
}

// MARK: - Reference mode

struct ToggleReferenceModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Reference Mode"
    static var description = IntentDescription(
        "Toggle SherlockEQ's reference (bypass) mode. Reference mode plays audio with the EQ disabled."
    )
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let service = try await AppControlService.awaitLive()
        let on = service.setBypass(.toggle)
        return .result(value: on,
                       dialog: on ? "Reference mode on — EQ bypassed." : "Reference mode off — EQ active.")
    }
}

struct SetReferenceModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Reference Mode"
    static var description = IntentDescription(
        "Turn SherlockEQ's reference (bypass) mode on or off. Reference mode plays audio with the EQ disabled."
    )
    static var openAppWhenRun = false

    @Parameter(title: "State")
    var state: ReferenceModeState

    static var parameterSummary: some ParameterSummary {
        Summary("Turn reference mode \(\.$state)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let service = try await AppControlService.awaitLive()
        let on = service.setBypass(state == .on ? .on : .off)
        return .result(value: on,
                       dialog: on ? "Reference mode on — EQ bypassed." : "Reference mode off — EQ active.")
    }
}

// MARK: - Master gain

struct SetMasterGainIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Master Gain"
    static var description = IntentDescription(
        "Set SherlockEQ's master output gain in decibels (-60 to +12 dB)."
    )
    static var openAppWhenRun = false

    @Parameter(title: "Gain (dB)")
    var gainDB: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Set master gain to \(\.$gainDB) dB")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let service = try await AppControlService.awaitLive()
        let applied = try service.setGain(gainDB)
        return .result(value: applied, dialog: "Master gain set to \(formatDB(applied)) dB.")
    }
}

struct AdjustMasterGainIntent: AppIntent {
    static var title: LocalizedStringResource = "Adjust Master Gain"
    static var description = IntentDescription(
        "Raise or lower SherlockEQ's master gain by a number of decibels. The result is clamped to the -60…+12 dB range."
    )
    static var openAppWhenRun = false

    @Parameter(title: "Change (dB)")
    var deltaDB: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Adjust master gain by \(\.$deltaDB) dB")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let service = try await AppControlService.awaitLive()
        let applied = service.adjustGain(by: deltaDB)
        return .result(value: applied, dialog: "Master gain is now \(formatDB(applied)) dB.")
    }
}

// MARK: - Balance

struct SetBalanceIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Balance"
    static var description = IntentDescription(
        "Set the active profile's stereo balance, from -1 (full left) through 0 (centered) to +1 (full right)."
    )
    static var openAppWhenRun = false

    @Parameter(title: "Balance")
    var balance: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Set balance to \(\.$balance)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let service = try await AppControlService.awaitLive()
        let applied = try service.setBalance(balance)
        return .result(value: applied, dialog: "Balance set to \(formatDB(applied)).")
    }
}

// MARK: - Profiles

struct ActivateProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "Activate Profile"
    static var description = IntentDescription("Make a SherlockEQ hearing profile the active one.")
    static var openAppWhenRun = false

    @Parameter(title: "Profile")
    var profile: ProfileEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Activate profile \(\.$profile)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = try await AppControlService.awaitLive()
        let resolved = try service.profile(id: profile.id)
        service.activate(resolved)
        return .result(dialog: "Activated \u{201C}\(resolved.name)\u{201D}.")
    }
}

struct GetActiveProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Active Profile"
    static var description = IntentDescription("Get SherlockEQ's currently active hearing profile.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ProfileEntity?> & ProvidesDialog {
        let service = try await AppControlService.awaitLive()
        guard let active = service.activeProfile() else {
            return .result(value: nil, dialog: "No profile is active.")
        }
        return .result(value: ProfileEntity(active), dialog: "The active profile is \u{201C}\(active.name)\u{201D}.")
    }
}

// MARK: - Simple EQ

struct SetSimpleEQIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Simple EQ"
    static var description = IntentDescription(
        "Set the active profile's Simple EQ bass, mid, and/or treble gain in decibels (-24 to +24 dB). Leave a field empty to keep its current value."
    )
    static var openAppWhenRun = false

    @Parameter(title: "Bass (dB)")
    var bass: Double?

    @Parameter(title: "Mid (dB)")
    var mid: Double?

    @Parameter(title: "Treble (dB)")
    var treble: Double?

    static var parameterSummary: some ParameterSummary {
        Summary("Set Simple EQ") {
            \.$bass
            \.$mid
            \.$treble
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = try await AppControlService.awaitLive()
        let values = try service.setSimpleEQ(bass: bass, mid: mid, treble: treble)
        let b = formatDB(values["bass"] ?? 0)
        let m = formatDB(values["mid"] ?? 0)
        let t = formatDB(values["treble"] ?? 0)
        return .result(dialog: "Simple EQ set — bass \(b), mid \(m), treble \(t) dB.")
    }
}

// MARK: - Status

struct GetStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get SherlockEQ Status"
    static var description = IntentDescription(
        "Get a summary of SherlockEQ's current state — active profile, master gain, reference mode, and output device."
    )
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let service = try await AppControlService.awaitLive()
        let profileName = service.activeProfile()?.name ?? "none"
        let summary = "Profile: \(profileName). "
            + "Master gain: \(formatDB(service.gainDB)) dB. "
            + "Reference mode: \(service.bypass ? "on" : "off"). "
            + "Output: \(service.outputDeviceName)."
        return .result(value: summary, dialog: "\(summary)")
    }
}
