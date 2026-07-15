import Foundation

/// Crash-resilient recovery for the CATap's output mute.
///
/// The tap engages `CATapMuteBehavior.mutedWhenTapped`, which mutes the real
/// output device's normal playback while SherlockEQ processes the audio. A
/// clean stop tears the tap down and the mute lifts. But if the process is
/// killed without running teardown — a crash, a force-quit, or an
/// `xcodebuild` test host being torn down — the device is left muted and the
/// user gets total silence with no obvious cause.
///
/// The fix is a **launch-time sentinel**. On tap start we persist a marker
/// (the tapped device UID + whether it was ALREADY muted before we touched
/// it). A clean teardown clears it. So a marker still present at the next
/// launch proves the previous run ended uncleanly — and if we're the reason
/// the device is muted, we unmute it.
///
/// Why not an `atexit` / signal handler instead? `SIGKILL` (force-quit, many
/// test-host teardowns) can't be caught at all, and CoreAudio's
/// `AudioObject*` APIs are not async-signal-safe, so unmuting from a signal
/// handler is neither reliable nor safe. The launch sentinel covers every
/// unclean-exit path uniformly.
// The whole namespace is `nonisolated`: recovery runs off the main actor (in
// the tap's nonisolated CoreAudio prep and on a background queue at launch),
// and the module defaults to MainActor isolation, which would otherwise make
// these members main-actor-bound.
nonisolated enum TapMuteSentinel {
    private static let key = "sherlockeq.tapMuteSentinel"

    /// What we knew at tap-start time. `preTapMuted` is the device's mute
    /// state *before* our tap engaged its mute — the guard that stops us from
    /// ever clearing a mute the user set themselves.
    struct Marker: Codable, Equatable, Sendable {
        let deviceUID: String?
        let preTapMuted: Bool
    }

    // MARK: - Persistence

    /// Record that the tap is active (its mute is engaged). Called on every
    /// successful tap start.
    static func markActive(deviceUID: String?, preTapMuted: Bool, defaults: UserDefaults = .standard) {
        let marker = Marker(deviceUID: deviceUID, preTapMuted: preTapMuted)
        if let data = try? JSONEncoder().encode(marker) {
            defaults.set(data, forKey: key)
        }
    }

    /// Clear the marker. Called on every clean teardown.
    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    /// A marker still present at launch means the previous run didn't clean up.
    static func staleMarker(defaults: UserDefaults = .standard) -> Marker? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    // MARK: - Decision (pure — unit-tested)

    /// Whether recovery should unmute, given a stale marker and the CURRENT
    /// device state. Conservative on every axis:
    /// - Only if we started from an **unmuted** device (`preTapMuted == false`)
    ///   — otherwise the mute was the user's, and we leave it.
    /// - Only if the device is **actually muted** right now (nothing to do
    ///   otherwise).
    /// - Only if the current default output device is the **same device** we
    ///   tapped (never touch a different device the user may have muted on
    ///   purpose). A nil UID on either side is treated as "can't confirm a
    ///   mismatch" and allowed, since the common single-device case reports a
    ///   stable UID.
    static func shouldUnmute(marker: Marker, currentDeviceUID: String?, currentlyMuted: Bool) -> Bool {
        guard marker.preTapMuted == false else { return false }
        guard currentlyMuted else { return false }
        if let tapped = marker.deviceUID, let current = currentDeviceUID, tapped != current {
            return false
        }
        return true
    }
}
