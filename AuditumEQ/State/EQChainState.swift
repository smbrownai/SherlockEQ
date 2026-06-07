import Foundation
import Combine

/// EQ-chain control surface — reference mode, test curve, the two
/// internal tones (test + calibration), the four per-stage bypass
/// toggles, and the one-shot notch-off reminder flag. Persists the
/// user's durable preferences (eqMasterEnabled / autoEQEnabled /
/// notchFilterEnabled / manualEQEnabled / hasShownNotchOffReminder)
/// to UserDefaults; the transient toggles (referenceMode,
/// testCurveEnabled, testToneEnabled, calibrationToneEnabled) don't.
///
/// AudioState bridges value changes back to the audio engine —
/// EQChainState publishes, AudioState pushes. Toggles whose flip
/// requires re-applying the active profile (the four per-stage
/// enables) are observed via separate sinks in AudioState that fire
/// applyActiveProfile().
@MainActor
final class EQChainState: ObservableObject {

    // MARK: - Transient toggles (not persisted)

    /// Transient ⌘B A/B toggle that bypasses the whole EQ chain.
    /// Distinct from `eqMasterEnabled` (the durable on/off).
    @Published var referenceMode: Bool = false

    /// When on, both per-ear cascades are reconfigured with a single
    /// +6 dB band at 3 kHz so the user can hear whether the chain is
    /// alive (audible parametric peak) without dialing in real bands.
    @Published var testCurveEnabled: Bool = false

    /// 440 Hz sine routed directly into mainMixer, bypassing the
    /// tap→source→EQ chain. Diagnostic: if audible while no audio
    /// source is producing sound, the output path is alive.
    @Published var testToneEnabled: Bool = false

    /// Plays the 1 kHz / −12 dBFS reference tone used by the SPL-
    /// calibration workflow in Safe Listening. Routed via mainMixer
    /// so the user's EQ doesn't colour it.
    @Published var calibrationToneEnabled: Bool = false

    // MARK: - Persisted per-stage bypass

    /// Master bypass for the whole SherlockEQ chain. Distinct from
    /// `referenceMode` (transient) — this is the user's durable
    /// preference, persisted across launches. When off, every stage
    /// passes through unmodified and the per-stage toggles below
    /// are visually disabled (their stored values stay intact so
    /// flipping back restores the chain).
    @Published var eqMasterEnabled: Bool = EQChainState.loadBool(
        key: EQChainState.eqMasterEnabledKey,
        default: true
    ) {
        didSet { UserDefaults.standard.set(eqMasterEnabled, forKey: Self.eqMasterEnabledKey) }
    }

    /// Per-stage toggle for AutoEQ headphone correction. On by
    /// default — if the user loaded a correction they almost
    /// certainly want it active.
    @Published var autoEQEnabled: Bool = EQChainState.loadBool(
        key: EQChainState.autoEQEnabledKey,
        default: true
    ) {
        didSet { UserDefaults.standard.set(autoEQEnabled, forKey: Self.autoEQEnabledKey) }
    }

    /// Per-stage toggle for the tinnitus notch. Profile-stored notch
    /// frequency/depth/Q are preserved when this is off, so flipping
    /// back restores the user's dialed-in settings.
    @Published var notchFilterEnabled: Bool = EQChainState.loadBool(
        key: EQChainState.notchFilterEnabledKey,
        default: true
    ) {
        didSet { UserDefaults.standard.set(notchFilterEnabled, forKey: Self.notchFilterEnabledKey) }
    }

    /// Per-stage toggle for the manual parametric EQ (Stage 4 — the
    /// bands the user dialed in via Simple / Speech / Advanced /
    /// Expert). When off, the profile's own bands drop out of the
    /// chain while AutoEQ correction and the notch keep working.
    @Published var manualEQEnabled: Bool = EQChainState.loadBool(
        key: EQChainState.manualEQEnabledKey,
        default: true
    ) {
        didSet { UserDefaults.standard.set(manualEQEnabled, forKey: Self.manualEQEnabledKey) }
    }

    // MARK: - One-shot UI flags

    /// Set after the user dismisses the notch-off reminder banner.
    /// The copy lives in the view layer; this flag just guards
    /// re-display across launches.
    @Published var hasShownNotchOffReminder: Bool = EQChainState.loadBool(
        key: EQChainState.hasShownNotchOffReminderKey,
        default: false
    ) {
        didSet { UserDefaults.standard.set(hasShownNotchOffReminder, forKey: Self.hasShownNotchOffReminderKey) }
    }

    // MARK: - UserDefaults plumbing

    private static let eqMasterEnabledKey = "sherlockeq.eqMasterEnabled"
    private static let autoEQEnabledKey = "sherlockeq.autoEQEnabled"
    private static let notchFilterEnabledKey = "sherlockeq.notchFilterEnabled"
    private static let manualEQEnabledKey = "sherlockeq.manualEQEnabled"
    private static let hasShownNotchOffReminderKey = "sherlockeq.hasShownNotchOffReminder"

    private static func loadBool(key: String, default defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }
}
