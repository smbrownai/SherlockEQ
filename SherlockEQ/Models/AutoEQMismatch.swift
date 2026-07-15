import Foundation

/// A headphone correction running on an output device it wasn't set up for
/// (phase3-make-correction-land.md §7).
///
/// The motivating incident: a DT770 Pro X correction (−6 dB preamp + 10
/// bands) stayed active while output was MacBook Air Speakers — the user
/// experienced ~6 dB quieter audio and lower meters with nothing in the app
/// connecting the dots. The app *knows* the correction's target device (it
/// records the output device at attach time) and *knows* the current output
/// device; this type is the comparison.
///
/// Detection is identity-based only — the device UID recorded when the
/// correction was attached versus the current default output's UID. No
/// fuzzy model-name matching, no guessing: a legacy correction with no
/// recorded UID produces no warning until it's re-attached.
struct AutoEQMismatch: Equatable {
    /// Display name of the correction ("Beyerdynamic DT770 Pro X …").
    let correctionName: String
    /// Name of the device the correction was attached on.
    let attachedDeviceName: String
    /// Name of the current output device.
    let currentDeviceName: String
    /// True when the current output is the Mac's built-in speakers — a
    /// headphone curve there is categorically wrong, and the warning copy
    /// says so more firmly.
    let currentIsBuiltInSpeakers: Bool
    /// Key for the per-(profile, device) dismissal memory — warn once per
    /// new combination, never nag.
    let dismissalKey: String

    /// One-sentence user-facing message.
    var message: String {
        if currentIsBuiltInSpeakers {
            return "The '\(correctionName)' headphone correction is active on your built-in speakers — it was set up for \(attachedDeviceName) and will mis-shape (and quiet) speaker output."
        }
        return "The '\(correctionName)' correction was set up for \(attachedDeviceName) — you're listening on \(currentDeviceName)."
    }

    /// Pure evaluation — all inputs explicit so the truth table is unit-
    /// testable without an audio engine or a store.
    ///
    /// Produces a mismatch only when ALL hold:
    ///  • the profile carries an enabled-in-chain AutoEQ correction
    ///    (bands present) and the session AutoEQ stage is on,
    ///  • the correction recorded its attach-time device (non-nil UID),
    ///  • the current output device is known and differs from it,
    ///  • the (profile, current device) pair hasn't been dismissed.
    static func evaluate(
        profile: HearingProfile?,
        autoEQStageEnabled: Bool,
        currentDeviceUID: String?,
        currentDeviceName: String,
        currentIsBuiltInSpeakers: Bool,
        dismissedKeys: Set<String>
    ) -> AutoEQMismatch? {
        guard let profile,
              autoEQStageEnabled,
              let bands = profile.autoEQBands, !bands.isEmpty,
              let attachedUID = profile.autoEQDeviceUID,
              let currentUID = currentDeviceUID,
              attachedUID != currentUID
        else { return nil }

        let key = Self.dismissalKey(profileID: profile.id, deviceUID: currentUID)
        guard !dismissedKeys.contains(key) else { return nil }

        return AutoEQMismatch(
            correctionName: profile.autoEQName ?? "Headphone correction",
            attachedDeviceName: profile.autoEQDeviceName ?? "another output device",
            currentDeviceName: currentDeviceName,
            currentIsBuiltInSpeakers: currentIsBuiltInSpeakers,
            dismissalKey: key
        )
    }

    static func dismissalKey(profileID: UUID, deviceUID: String) -> String {
        "\(profileID.uuidString)|\(deviceUID)"
    }
}
