import Foundation
import AppKit
import AVFoundation
import Combine
import CoreAudio
import OSLog
import os
import ServiceManagement
import SwiftUI

/// How much we actually know about today's exposure right now.
///
/// - `unknown`: no audio is playing and nothing has accumulated — we have no
///   measurement, which is *not* the same as a measurement of zero.
/// - `approximate`: tracking, but without playback calibration the number has
///   the right shape and the wrong level.
/// - `tracked`: calibrated and measuring; the only state that has earned a
///   plain, unqualified reading.
///
/// Lives here (not on a view) because the Safe Listening screen and the
/// menu-bar popover must answer this identically.
///
/// `nonisolated` (the project defaults types to MainActor): this is pure data
/// plus a pure rule, so it shouldn't require the main actor to compare — and
/// under Swift 6 a MainActor-isolated `Equatable` conformance is unusable from
/// the nonisolated tests that guard it.
nonisolated enum ExposureStatus {
    case unknown, approximate, tracked

    /// Below this dBA the level reading is treated as "no audio" rather than a
    /// real quiet reading — matches the level meter's own floor.
    static let audioFloorDBA: Double = 31

    /// The rule itself, kept pure so it's directly testable and can't drift
    /// between the surfaces that render it.
    ///
    /// Note the asymmetry: accumulated exposure keeps its reading even after
    /// the audio stops (it genuinely happened), so only a zero dose with no
    /// audio is `unknown`.
    static func resolve(sessionDose: Double,
                        levelDBA: Double,
                        hasCalibration: Bool) -> ExposureStatus {
        let receivingAudio = levelDBA >= audioFloorDBA
        if sessionDose <= 0 && !receivingAudio { return .unknown }
        return hasCalibration ? .tracked : .approximate
    }
}
import UserNotifications

/// Single source of truth for audio lifecycle, injected as `@EnvironmentObject`
/// into both popover and main-window hierarchies (Session 4+). Currently wires
/// the tap → AVAudioEngine handoff and exposes the reference-mode / test-curve
/// toggles to the UI.
@MainActor
final class AudioState: ObservableObject {

    @Published private(set) var tap: CATapEngine
    @Published private(set) var audio: SherlockEQAudioEngine
    @Published private(set) var spectrum: SpectrumAnalyzer
    @Published private(set) var preSpectrum: SpectrumAnalyzer
    @Published private(set) var stereoMonitor: StereoMonitor
    @Published private(set) var safeListening: SafeListeningTracker

    /// 7-day (well, 90-day retained) daily dose-peak history. The tracker
    /// finalizes each day into this at the midnight rollover; the Safe
    /// Listening chart reads it. A plain `let` — views that need it observe it
    /// directly via `@ObservedObject` rather than through AudioState, since
    /// records change at most once a day and don't warrant a rebroadcast.
    let doseHistory = DoseHistoryStore()

    /// Daily subjective tinnitus-annoyance check-ins (non-clinical). Like
    /// `doseHistory`, a plain `let` observed directly by the Tinnitus Notch
    /// screen — records change at most once a day.
    let tinnitusCheckIns = TinnitusCheckInStore()

    /// EQ-chain control surface — see `EQChainState`. AudioState
    /// sinks each `$value` publisher (in init) and pushes the result
    /// into the engine. The four per-stage toggles also kick
    /// applyActiveProfile() on change so the chain rebuilds against
    /// the new bypass mask.
    let eqChain = EQChainState()

    /// Display-rate activity telemetry for the dynamic-EQ stage. A plain
    /// `let` (not `@Published`) so its 15 Hz refresh is never rebroadcast
    /// through AudioState — meter views observe it directly. Provider is
    /// wired in `init` once `tap` exists.
    let dynamicActivity = DynamicActivityMonitor()

    /// Display-rate telemetry for the Adaptive Correction stage's live
    /// per-band gains (phase4 §6.2) — same plain-`let` discipline; the
    /// canvas overlay observes it directly.
    let adaptiveActivity = AdaptiveActivityMonitor()

    /// dBFS level of the calibration tone, exposed so the UI can compute
    /// the offset between the meter reading and the slider value. Always
    /// matches `SherlockEQAudioEngine.calibrationToneDBFS`.
    var calibrationToneLevelDBFS: Float { SherlockEQAudioEngine.calibrationToneDBFS }

    /// Master gain + AUPeakLimiter knobs — see `EngineParameters`.
    /// AudioState sinks each `$value` publisher (in init) and pushes
    /// the result into the engine, so EngineParameters itself knows
    /// nothing about the engine.
    let engineParameters = EngineParameters()

    /// App-wide UI / shell preferences (per-ear colors, dock,
    /// launch-at-login, global reference shortcut) — see `AppPreferences`.
    let preferences = AppPreferences()

    /// AutoEQ-specific preferences (library folder) — see `AutoEQPreferences`.
    let autoEQPreferences = AutoEQPreferences()

    private static func loadDouble(key: String, default defaultValue: Double) -> Double {
        let raw = UserDefaults.standard.object(forKey: key) as? Double
        return raw ?? defaultValue
    }

    /// ID of the currently-active hearing profile. The profile itself lives in
    /// `ProfileStore`; we hold only the ID so the store remains the source of
    /// truth and edits naturally flow through `ProfileStore.save(_:)`.
    /// Persisted to UserDefaults so the user's selection survives across launches.
    @Published var activeProfileID: UUID? = AudioState.loadActiveProfileID() {
        didSet {
            let defaults = UserDefaults.standard
            if let id = activeProfileID {
                defaults.set(id.uuidString, forKey: Self.activeProfileIDKey)
            } else {
                defaults.removeObject(forKey: Self.activeProfileIDKey)
            }
        }
    }
    static let activeProfileIDKey = "sherlockeq.activeProfileID"
    private static func loadActiveProfileID() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: activeProfileIDKey) else { return nil }
        return UUID(uuidString: raw)
    }

    /// Cross-window deep-link request. A surface that lives outside the main
    /// window (the onboarding wizard's "next steps" cards, say) sets this to
    /// ask `MainWindowView` to switch its sidebar selection. `MainWindowView`
    /// observes it, applies the value to its local selection state, and clears
    /// it back to nil. Not persisted — it's a one-shot navigation intent.
    @Published var pendingMainSection: SidebarSection?

    /// Presents the consolidated Health & Safety disclosure sheet. Set from
    /// the persistent sidebar item and every compact disclosure chip, observed
    /// by `MainWindowView` which owns the `.sheet`. Not persisted.
    @Published var showHealthSafety = false

    // NOTE (dose observation): AudioState deliberately carries NO mirrored
    // dose properties. The old @Published mirrors re-rendered every
    // @EnvironmentObject view tree at 1 Hz during playback (perf review
    // S1). Reading `audioState.safeListening.…` from a view body does NOT
    // observe the tracker — SwiftUI never subscribes to a nested
    // ObservableObject reached through a property — so every dose surface
    // holds its own throttled subscription: LiveLevelBody / DoseCardBody
    // (SafeListeningView), PopoverLiveStatusRows (MainPopoverView), and
    // MonitorDoseCard (MonitorSidebar). Threshold/severity helpers belong
    // on `SafeListeningTracker` so all surfaces see the same answer.

    /// Latest dBA staged by the render thread's level pass, drained by
    /// `doseDrainTimer`. See the wiring comment at `onLevelUpdate` (RT-01).
    private let doseLevelSlot = OSAllocatedUnfairLock<Float?>(initialState: nil)
    private var doseDrainTimer: Timer?

    /// Banner state — see `NoticeCenter`. Views access it via
    /// `audioState.noticeCenter.userVisibleNotice`.
    let noticeCenter = NoticeCenter()

    /// SPL calibration in dB: the dB SPL the user actually hears when a
    /// 0 dBFS signal plays through the current output device at their
    /// current volume. Drives the dBFS → dBA conversion used by the dose
    /// tracker and the canvas's safety-threshold curve. Default 100 is the
    /// "consumer-headphones at moderate volume" rule of thumb from spec
    /// §5.4 — quieter listeners should set this lower (e.g. 85), louder
    /// listeners higher (e.g. 110). Persisted so the user only calibrates
    /// once per setup.
    ///
    /// Setting this value also re-anchors the calibration to the *current*
    /// system output volume (see `calibrationAnchor`): "at this volume,
    /// 0 dBFS is X dB SPL" is the statement the user is making. The dose
    /// pipeline consumes `effectiveCalibrationOffsetDBA`, which shifts this
    /// base by the live volume delta.
    @Published var calibrationOffsetDBA: Double = AudioState.loadDouble(
        key: AudioState.calibrationKey,
        default: 100
    ) {
        didSet {
            UserDefaults.standard.set(calibrationOffsetDBA, forKey: Self.calibrationKey)
            snapshotCalibrationAnchor()
            refreshVolumeDelta()
        }
    }
    static let calibrationKey = "sherlockeq.calibrationOffsetDBA"

    // MARK: - Volume-aware calibration (see volume-aware-dose.md)

    /// Always-on system-output-volume tracker. CATap captures audio upstream
    /// of the hardware volume, so the dose estimate must track the volume
    /// keys itself. Separate instance from the Analog Control Unit's
    /// window-lifecycle one — two HAL listeners are trivial, and sharing
    /// would couple that window's start/stop to the dose tracker.
    let systemVolume = SystemVolumeController()

    /// Live dB shift between the volume at calibration time and now. `0`
    /// whenever tracking can't apply (no anchor, unreadable volume, device
    /// mismatch) — the legacy fixed-offset behavior.
    @Published private(set) var volumeDeltaDB: Double = 0

    /// What the dBFS → dBA conversion actually uses: the user's calibration
    /// shifted by the live volume delta. Display surfaces that show at-ear
    /// level (meter zone boundaries, canvas safety overlay) read this; the
    /// Safe Listening calibration slider binds the base value.
    var effectiveCalibrationOffsetDBA: Double { calibrationOffsetDBA + volumeDeltaDB }

    /// Volume-tracking condition for the Safe Listening status row. Derived
    /// from the same pure function as `volumeDeltaDB` so copy and math agree.
    var volumeTrackingStatus: CalibrationVolumeAnchor.Status {
        CalibrationVolumeAnchor.status(
            anchor: calibrationAnchor,
            currentVolumeDB: systemVolume.volumeDB,
            currentDeviceUID: systemVolume.deviceUID,
            isMuted: systemVolume.isMuted)
    }

    /// Volume + device recorded the last time the calibration was set.
    /// `nil` on legacy installs (calibrated before volume tracking) and when
    /// the device exposed no readable volume at calibration time.
    private var calibrationAnchor: CalibrationVolumeAnchor? = AudioState.loadCalibrationAnchor()

    static let calibrationAnchorVolumeKey = "sherlockeq.calibrationAnchorVolumeDB"
    static let calibrationAnchorDeviceKey = "sherlockeq.calibrationAnchorDeviceUID"

    private static func loadCalibrationAnchor() -> CalibrationVolumeAnchor? {
        let defaults = UserDefaults.standard
        guard let db = defaults.object(forKey: calibrationAnchorVolumeKey) as? Double,
              let uid = defaults.string(forKey: calibrationAnchorDeviceKey) else { return nil }
        return CalibrationVolumeAnchor(volumeDB: db, deviceUID: uid)
    }

    /// Record (or clear) the volume anchor for the calibration that was just
    /// set. Unreadable volume → no anchor → delta stays 0 (legacy behavior).
    private func snapshotCalibrationAnchor() {
        let defaults = UserDefaults.standard
        if let db = systemVolume.volumeDB, let uid = systemVolume.deviceUID,
           !systemVolume.isMuted {
            calibrationAnchor = CalibrationVolumeAnchor(volumeDB: db, deviceUID: uid)
            defaults.set(db, forKey: Self.calibrationAnchorVolumeKey)
            defaults.set(uid, forKey: Self.calibrationAnchorDeviceKey)
        } else {
            calibrationAnchor = nil
            defaults.removeObject(forKey: Self.calibrationAnchorVolumeKey)
            defaults.removeObject(forKey: Self.calibrationAnchorDeviceKey)
        }
    }

    /// Recompute the live volume delta and push the *effective* calibration
    /// into both analyzers. Called on every controller publish and whenever
    /// the base calibration changes; both are rare (HAL property listeners
    /// fire on actual changes, no polling).
    private func refreshVolumeDelta() {
        let delta = CalibrationVolumeAnchor.deltaDB(
            anchor: calibrationAnchor,
            currentVolumeDB: systemVolume.volumeDB,
            currentDeviceUID: systemVolume.deviceUID,
            isMuted: systemVolume.isMuted)
        if delta != volumeDeltaDB { volumeDeltaDB = delta }
        let effective = Float(calibrationOffsetDBA + delta)
        spectrum.calibrationOffsetDBA = effective
        preSpectrum.calibrationOffsetDBA = effective
        // Adaptive Correction reads the same anchor (phase4 §4.2): its
        // gains follow the volume keys — quieter listening genuinely gets
        // more correction — and the §7.3 reduced-depth cap applies until
        // the user has actually performed the calibration once.
        audio.setAdaptiveLevelAnchor(
            offsetDBA: Double(effective),
            calibrated: hasUserCalibration
        )
    }

    /// §7.3: true once the user has ever set the SPL calibration (slider
    /// or meter-reading Apply persists the key). The default rule-of-thumb
    /// offset alone runs Adaptive in its reduced-depth mode.
    var hasUserCalibration: Bool {
        UserDefaults.standard.object(forKey: Self.calibrationKey) != nil
    }

    /// Whether audio is actually flowing right now. Live (not the throttled
    /// mirror), so only read it from surfaces that already track the tracker.
    var isReceivingAudio: Bool {
        safeListening.currentLevelDBA >= ExposureStatus.audioFloorDBA
    }

    /// The honest read of today's exposure, shared by the Safe Listening screen
    /// and the menu-bar popover so the two can't drift into telling different
    /// stories about the same number. Rule lives in `ExposureStatus.resolve`.
    var exposureStatus: ExposureStatus {
        ExposureStatus.resolve(sessionDose: safeListening.sessionDose,
                               levelDBA: safeListening.currentLevelDBA,
                               hasCalibration: hasUserCalibration)
    }

    func activeProfile(in store: ProfileStore) -> HearingProfile? {
        guard let id = activeProfileID else { return nil }
        return store.profiles.first { $0.id == id }
    }

    /// On first launch, point the popover and audio engine at a sensible
    /// default. If the persisted active profile still exists, keep it. Else
    /// prefer the Music Balanced factory preset (the neutral default), and
    /// only fall back to the first available profile if it's somehow absent.
    /// This also covers the existing-install migration case where the old
    /// active built-in was deleted during factory-preset reconciliation.
    func adoptDefaultProfileIfNeeded(from store: ProfileStore) {
        if let id = activeProfileID, store.profiles.contains(where: { $0.id == id }) {
            return
        }
        if store.profiles.contains(where: { $0.id == HearingProfile.defaultActiveFactoryID }) {
            activeProfileID = HearingProfile.defaultActiveFactoryID
        } else {
            activeProfileID = store.profiles.first?.id
        }
    }

    /// Bridge profile state into the audio engine. Subscribes to the active
    /// profile ID and the store's profile array so a change to either
    /// (switching profiles, editing the active profile's audiogram/trim)
    /// re-applies the resulting bands to the EQ nodes.
    func connect(profileStore: ProfileStore) {
        connectedStore = profileStore
        profileSubscriptions.removeAll()

        // `@Published` fires its publisher in the property's `willSet`,
        // *before* the value is actually assigned. If we call
        // `applyActiveProfile()` directly inside the sink we read the
        // store's *old* state and push the wrong profile to the engine.
        // The bug bit a single-shot save (e.g. the "Center balance"
        // recenter button) hardest: only one save fires, so the engine
        // ends up holding whatever was there immediately before — the
        // UI says "Center" while the audio chain is still at L 100 %.
        // Slider drags hid it because each tick's apply caught up to
        // the previous tick's save. Defer to the next main-actor turn
        // so the assignment has landed by the time we read.
        $activeProfileID
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.applyActiveProfile() }
            }
            .store(in: &profileSubscriptions)

        profileStore.$profiles
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.applyActiveProfile() }
            }
            .store(in: &profileSubscriptions)

        // Surface persistence errors in the main-window banner. The
        // store sets `lastError` from its `tracking` wrapper, so we
        // get a notification at the exact moment any save / delete /
        // import / export / relocate / loadAll fails. NoticeCenter
        // owns the sink so the wiring stays with the consumer.
        noticeCenter.bind(to: profileStore)

        applyActiveProfile()
    }

    /// Proxy through to `noticeCenter.showNotice`. Kept on AudioState
    /// so internal callers (e.g. `checkNotificationsDeniedAtAmberDose`)
    /// don't need to know about the indirection yet.
    func showNotice(_ notice: TransientNotice) {
        noticeCenter.showNotice(notice)
    }

    /// Proxy through to `noticeCenter.dismissNotice`.
    func dismissNotice() {
        noticeCenter.dismissNotice()
    }

    /// When the system output device changes, switch the active profile to
    /// any profile linked to that device's UID. First match wins. No-op if
    /// no profile is linked to the new device — the user keeps whichever
    /// profile they had active.
    /// Device UIDs we've already warned carry duplicate (legacy) links —
    /// once per session per device keeps the banner informative, not naggy.
    private var warnedShadowedLinkUIDs: Set<String> = []

    private func autoSwitchProfileIfLinked(deviceID: AudioDeviceID) {
        guard let store = connectedStore,
              let uid = try? CATapEngine.deviceUID(deviceID) else { return }
        let matches = store.profiles.filter { $0.linkedDeviceUID == uid }
        guard let match = matches.first else { return }

        // ProfileStore.linkDevice enforces one-device-one-profile on every
        // new link, so duplicates can only be legacy data from before that
        // invariant existed. Keep the historical winner (first in the
        // createdAt-sorted array) for those users rather than silently
        // changing which profile activates — but say so, once per device per
        // session, since the shadowed link otherwise fails with no feedback.
        if matches.count > 1, !warnedShadowedLinkUIDs.contains(uid) {
            warnedShadowedLinkUIDs.insert(uid)
            let names = matches.map(\.name).joined(separator: ", ")
            noticeCenter.showNotice(TransientNotice(
                severity: .warning,
                message: "\(matches.count) profiles are linked to this output device (\(names)). Using “\(match.name)” — relink a profile in Profiles to choose a different one."
            ))
        }

        guard match.id != activeProfileID else { return }
        log.info("Auto-switching to \(match.name, privacy: .private) for device UID \(uid, privacy: .private)")
        activeProfileID = match.id
    }

    // MARK: - Analog Control Unit override

    /// While the Analog Control Unit window is open, this transient profile
    /// drives the audio in place of the store's active profile. The store's
    /// active profile is never touched, so closing the window restores it
    /// automatically — and this profile never enters the store, so it never
    /// appears in the picker.
    ///
    /// Deliberately bare — a simple bass/mid/treble tone + balance, nothing
    /// else: no audiogram, notch, clarity, or AutoEQ ("really old school";
    /// revisit later). Persisted across opens so the analog tone is remembered.
    @Published private(set) var analogOverrideProfile: HearingProfile?

    private static let analogProfileKey = "sherlockeq.analogControlUnit.profile"

    /// Enter analog mode: load the persisted bare profile (or a fresh flat
    /// one) and route the audio through it.
    func beginAnalogOverride() {
        analogOverrideProfile = Self.loadAnalogProfile() ?? Self.makeAnalogProfile()
        applyActiveProfile()
    }

    /// Leave analog mode: persist the tone and resume the real active profile.
    func endAnalogOverride() {
        if let profile = analogOverrideProfile { Self.saveAnalogProfile(profile) }
        analogOverrideProfile = nil
        applyActiveProfile()
    }

    /// Apply a knob edit to the analog profile and re-apply it live. Persists
    /// on every change so the tone survives across opens.
    func updateAnalogOverride(_ mutate: (inout HearingProfile) -> Void) {
        guard var profile = analogOverrideProfile else { return }
        mutate(&profile)
        analogOverrideProfile = profile
        Self.saveAnalogProfile(profile)
        applyActiveProfile()
    }

    /// A bare profile: flat audiogram, no notch / clarity / AutoEQ, linked
    /// channels. Only the three tone bands (bass/mid/treble shelves + bell)
    /// and balance ever change; the profile never renders in the Equalizer
    /// UI, so its eqMode is inert (Graphic, like every new profile).
    private static func makeAnalogProfile() -> HearingProfile {
        var profile = HearingProfile.makeDefault(name: "Analog Control Unit", symbol: "dial.medium.fill")
        profile.eqMode = .advanced
        profile.separateChannels = false
        return profile
    }

    private static func saveAnalogProfile(_ profile: HearingProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: analogProfileKey)
        }
    }

    private static func loadAnalogProfile() -> HearingProfile? {
        guard let data = UserDefaults.standard.data(forKey: analogProfileKey) else { return nil }
        return try? JSONDecoder().decode(HearingProfile.self, from: data)
    }

    /// Look up the active profile in the connected store and push it to the
    /// engine. No-op if a store isn't connected yet or the test curve is
    /// currently overriding. When the active profile resolves to nil (the
    /// user deleted the active profile, or no profile has been picked
    /// yet) the cascade is flattened so the user doesn't keep hearing the
    /// previously-applied bands while the popover shows "no profile".
    ///
    /// Applies the four-stage bypass mask before handing off to the
    /// engine. The store's profile stays untouched — toggles flatten
    /// a local copy so flipping a stage back on restores immediately
    /// without re-reading anything from disk.
    private func applyActiveProfile() {
        // Every path that changes what's applied also re-evaluates the
        // AutoEQ device-mismatch state (profile switch, correction edit,
        // per-stage toggle flips all funnel through here).
        defer { refreshAutoEQMismatch() }
        guard !eqChain.testCurveEnabled else { return }
        // The Analog Control Unit overrides the applied profile while open;
        // the store's active profile is left untouched and resumes on close.
        if let override = analogOverrideProfile {
            audio.applyProfile(applyBypassMask(to: override))
            return
        }
        guard let store = connectedStore else { return }
        guard let original = activeProfile(in: store) else {
            audio.flattenChain()
            return
        }
        audio.applyProfile(applyBypassMask(to: original))
    }

    // MARK: - AutoEQ device-mismatch warning (spec §7 / AutoEQMismatch)

    /// Non-nil while the active profile's headphone correction is running
    /// on an output device it wasn't attached on. Surfaced as a popover row
    /// and an Equalizer chip; never auto-acts (no silent audio changes).
    @Published private(set) var autoEQMismatch: AutoEQMismatch?

    private static let autoEQDismissalsKey = "sherlockeq.autoEQMismatch.dismissed"

    /// Per-(profile, device) dismissal memory — warn once per new
    /// combination, never nag.
    private var autoEQDismissals: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: AudioState.autoEQDismissalsKey) ?? [])

    /// Recompute from current facts. Cheap and idempotent; called from
    /// `applyActiveProfile` and the tap's device-identity publisher.
    private func refreshAutoEQMismatch() {
        let profile = connectedStore.flatMap { activeProfile(in: $0) }
        let next = AutoEQMismatch.evaluate(
            profile: profile,
            autoEQStageEnabled: eqChain.eqMasterEnabled && eqChain.autoEQEnabled
                && (profile?.autoEQEnabled ?? true),
            currentDeviceUID: tap.currentOutputDeviceUID,
            currentDeviceName: tap.currentOutputDeviceName,
            currentIsBuiltInSpeakers: tap.currentOutputDeviceIsBuiltIn,
            dismissedKeys: autoEQDismissals
        )
        if next != autoEQMismatch { autoEQMismatch = next }
    }

    /// "Dismiss" — remember this (profile, device) pair and hide the
    /// warning until either changes to a new combination.
    func dismissAutoEQMismatch() {
        guard let mismatch = autoEQMismatch else { return }
        autoEQDismissals.insert(mismatch.dismissalKey)
        UserDefaults.standard.set(Array(autoEQDismissals), forKey: Self.autoEQDismissalsKey)
        autoEQMismatch = nil
    }

    /// "Bypass here" — turn this profile's correction off, clearing the
    /// warning (no correction applied → no mismatch). Deliberately NOT
    /// remembered as a dismissal: switching it back on against the same
    /// device should warn again.
    ///
    /// Writes the profile's own flag rather than the chain-level bypass. The
    /// mismatch is a statement about *this* profile's correction against the
    /// current device, so silencing it by muting the stage for every other
    /// profile would be far wider than the warning it answers.
    func bypassAutoEQForSession() {
        guard let store = connectedStore, let profile = activeProfile(in: store) else { return }
        var updated = store.profiles.first { $0.id == profile.id } ?? profile
        guard updated.autoEQEnabled else { return }
        updated.autoEQEnabled = false
        try? store.save(updated, actionName: "Bypass headphone correction")
    }

    /// Return a copy of `profile` with the appropriate stages zeroed
    /// per the current per-stage toggle state. Master `eqMasterEnabled`
    /// short-circuits everything (mirrors Reference Mode behavior for
    /// the durable toggle). Individual toggles flatten just their
    /// stage so other stages keep working.
    private func applyBypassMask(to profile: HearingProfile) -> HearingProfile {
        var copy = profile
        if !eqChain.eqMasterEnabled {
            copy.autoEQBands = nil
            copy.autoEQPreampDB = nil
            copy.leftNotch.enabled = false
            copy.rightNotch.enabled = false
            copy.leftEar.bands = []
            copy.rightEar.bands = []
            // Master off means truly flat — drop the audiogram correction
            // layer as well, not just the user/preset EQ. (The per-stage
            // `manualEQEnabled` toggle below intentionally leaves the
            // correction running: it flattens only the tone shaping on top.)
            copy.leftEar.correctionBands = []
            copy.rightEar.correctionBands = []
            copy.globalTrimDB = 0
            copy.dynamics = DynamicProcessingSettings()
            return copy
        }
        // Two independent switches, both of which must be on: the profile's
        // own flag (does this profile use its correction) and the chain-level
        // per-stage bypass (Debug's A/B). Either one off means no correction.
        if !eqChain.autoEQEnabled || !profile.autoEQEnabled {
            copy.autoEQBands = nil
            copy.autoEQPreampDB = nil
        }
        if !eqChain.notchFilterEnabled {
            copy.leftNotch.enabled = false
            copy.rightNotch.enabled = false
        }
        if !eqChain.manualEQEnabled {
            copy.leftEar.bands = []
            copy.rightEar.bands = []
        }
        if !eqChain.dynamicsEnabled {
            copy.dynamics = DynamicProcessingSettings()
        }
        return copy
    }

    private var tapObserver: AnyCancellable?
    private var audioObserver: AnyCancellable?
    private var systemVolumeObserver: AnyCancellable?
    private var tapDeviceObserver: AnyCancellable?
    private var trackerObserver: AnyCancellable?
    private var noticeObserver: AnyCancellable?
    private var preferencesObserver: AnyCancellable?
    private var autoEQPreferencesObserver: AnyCancellable?
    private var engineParametersObserver: AnyCancellable?
    private var engineParameterSubscriptions: Set<AnyCancellable> = []
    private var eqChainObserver: AnyCancellable?
    private var eqChainSubscriptions: Set<AnyCancellable> = []
    private var profileSubscriptions: Set<AnyCancellable> = []
    private weak var connectedStore: ProfileStore?
    private var sleepObserverToken: NSObjectProtocol?
    private var wakeObserverToken: NSObjectProtocol?
    private var didBecomeActiveObserverToken: NSObjectProtocol?
    private var sessionResignObserverToken: NSObjectProtocol?
    private var sessionActiveObserverToken: NSObjectProtocol?
    private var dayChangedObserverToken: NSObjectProtocol?
    private var wasRunningBeforeSleep = false
    private var wasRunningBeforeSessionResign = false
    private let log = Logger(subsystem: "com.shawnbrown.SherlockEQ", category: "AudioState")

    init() {
        // Crash-mute recovery (see `TapMuteSentinel`): if the previous run was
        // killed with its tap active, the output device is left muted. Consume
        // any stale marker synchronously here — before this session's tap start
        // writes a fresh one — and unmute off-main if we own the mute.
        Self.recoverStaleTapMuteIfNeeded()

        let tap = CATapEngine()
        let audio = SherlockEQAudioEngine()
        let spectrum = SpectrumAnalyzer()
        let preSpectrum = SpectrumAnalyzer()
        let stereoMonitor = StereoMonitor()
        let tracker = SafeListeningTracker()
        self.tap = tap
        self.audio = audio
        self.spectrum = spectrum
        self.preSpectrum = preSpectrum
        self.stereoMonitor = stereoMonitor
        self.safeListening = tracker
        // Load persisted history and route the tracker's day-finalize callback
        // into it BEFORE beginDailyTracking() — its restore step may finalize a
        // prior day immediately (app closed across midnight), and the callback
        // must already be wired to catch it.
        let history = doseHistory
        history.loadAll()
        tinnitusCheckIns.loadAll()
        tracker.onDayFinalized = { [weak history] dayStart, peak in
            history?.record(dayStart: dayStart, peakDose: peak)
        }
        // Restore today's accumulated dose from the previous run and start the
        // midnight-rollover timer. Kept here (not in the tracker's init) so
        // bare trackers built in unit tests don't touch the shared defaults.
        tracker.beginDailyTracking()

        // Activity meters read live gain deltas from the per-ear dynamic
        // processors (owned by the tap). Provider runs on the main actor
        // (the monitor's 15 Hz timer) — reading the lock-guarded counters
        // is cheap and thread-safe.
        dynamicActivity.deltaMilliDBProvider = { [weak tap] kind, ear in
            guard let tap else { return 0 }
            let proc = ear == .left ? tap.leftDynamics : tap.rightDynamics
            return proc.currentDeltaMilliDB(kind)
        }
        adaptiveActivity.gainMilliDBProvider = { [weak tap] ear, band in
            guard let tap else { return 0 }
            let proc = ear == .left ? tap.leftAdaptive : tap.rightAdaptive
            return proc.currentGainMilliDB(band: band)
        }

        tap.onOutputDeviceChanged = { [weak self] deviceID in
            Task { @MainActor in
                self?.scheduleRebuild()
                self?.autoSwitchProfileIfLinked(deviceID: deviceID)
            }
        }

        // AVAudioEngine sometimes reconfigures itself (Bluetooth route
        // change, sample-rate renegotiation, etc.) and stops rendering
        // until the graph is rebuilt. The notification can land at any
        // time — already on main via the observer's Task hop in
        // `SherlockEQAudioEngine`. Funnel it through the same coalescing
        // rebuild so a config-change that accompanies a device switch
        // doesn't race the device-change rebuild.
        audio.onConfigurationChange = { [weak self] in
            self?.scheduleRebuild()
        }

        // No always-on subscribe. Both analyzers run a CHEAP level pass in
        // `ingest` (one vDSP_measqv per buffer + a 20 Hz onLevelUpdate fire)
        // unconditionally, so dose tracking keeps working when no canvas
        // observes the FFT pipeline. The expensive FFT + smoothing + main-
        // actor publish only run while a `LiveParametricCanvas` is on screen
        // — see its subscribe/unsubscribe lifecycle.

        // Apply persisted SPL calibration to both analyzers so the dBA
        // figures the dose tracker integrates match the user's setup, then
        // start tracking the system output volume: the effective offset
        // shifts with the volume keys (see volume-aware-dose.md). The
        // controller publishes on actual HAL changes only; the sink defers
        // one main-actor turn because @Published sinks fire in willSet,
        // before the new values are readable (see published-willset rule).
        refreshVolumeDelta()
        systemVolume.start()
        systemVolumeObserver = systemVolume.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.refreshVolumeDelta() }
        }

        // AutoEQ device-mismatch check rides the tap's device-identity
        // publisher — the UID lands when `applyTapPrep` finishes a rebuild,
        // i.e. strictly after a device change has actually taken effect
        // (`onOutputDeviceChanged` fires before the new identity resolves).
        // Deferred one turn per the @Published willSet rule.
        tapDeviceObserver = tap.$currentOutputDeviceUID.sink { [weak self] _ in
            Task { @MainActor in self?.refreshAutoEQMismatch() }
        }

        // Spectrum analyzer → dose tracker, via a staging slot.
        // `onLevelUpdate` fires on the AUDIO RENDER THREAD (~20 Hz from the
        // cheap level pass); the old closure heap-allocated a Task there on
        // every fire (audit RT-01). Mirror StereoMonitor's pattern instead:
        // the render side only stores the latest dBA under an unfair lock —
        // no allocation — and a 10 Hz main timer drains it into the tracker.
        // The tracker's NIOSH integration is wall-clock self-timed ("~10 Hz
        // is plenty" per its docs), so the cadence change doesn't skew dose.
        spectrum.onLevelUpdate = { [doseLevelSlot] dba in
            doseLevelSlot.withLock { $0 = dba }
        }
        let drain = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            // Scheduled on RunLoop.main → fires on the main thread.
            MainActor.assumeIsolated { self?.drainDoseLevelSlot() }
        }
        RunLoop.main.add(drain, forMode: .common)
        doseDrainTimer = drain

        // Re-broadcast child object changes so SwiftUI views observing AudioState
        // refresh when any child's @Published state changes.
        tapObserver = tap.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        audioObserver = audio.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // Rebroadcast so views observing AudioState re-evaluate when the
        // banner state (`noticeCenter.userVisibleNotice`) changes.
        // NoticeCenter publishes infrequently — one shot per banner — so
        // this doesn't suffer the high-rate issue that excludes the
        // analyzers / monitor below.
        noticeObserver = noticeCenter.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        // Surface tap permission denials / failures + AVAudioEngine
        // errors in the banner. ProfileStore.lastError flows through
        // a third bind() at `connect(profileStore:)`. Together these
        // three sinks cover every persistent error path that
        // previously only showed up in DebugView.
        noticeCenter.bindTapState(tap)
        noticeCenter.bindAudioLastError(audio)
        // Same rebroadcast for prefs — Settings toggles, color picks
        // etc. should refresh views observing AudioState. These are
        // user-driven (low rate), so the cost is negligible.
        preferencesObserver = preferences.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        autoEQPreferencesObserver = autoEQPreferences.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        // EngineParameters lives outside the engine and just publishes
        // values; AudioState bridges each value back into the engine.
        // dropFirst() because the initial published value was already
        // applied by rebuildAudioGraph (or is about to be on first
        // start); subsequent user-driven changes flow through these.
        engineParameters.$masterGainDB
            .dropFirst()
            .sink { [weak self] db in self?.audio.setMasterGain(dB: db) }
            .store(in: &engineParameterSubscriptions)
        engineParameters.$limiterAttackMs
            .dropFirst()
            .sink { [weak self] ms in self?.audio.setLimiterAttack(seconds: ms / 1000.0) }
            .store(in: &engineParameterSubscriptions)
        engineParameters.$limiterDecayMs
            .dropFirst()
            .sink { [weak self] ms in self?.audio.setLimiterDecay(seconds: ms / 1000.0) }
            .store(in: &engineParameterSubscriptions)
        engineParameters.$limiterPreGainDB
            .dropFirst()
            .sink { [weak self] db in self?.audio.setLimiterPreGain(dB: db) }
            .store(in: &engineParameterSubscriptions)
        // Rebroadcast so views observing AudioState refresh on knob
        // changes (Settings, popover gain row).
        engineParametersObserver = engineParameters.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        // EQ-chain control surface — same pattern as EngineParameters.
        // Transient toggles push directly to the engine; the four
        // per-stage toggles ALSO kick applyActiveProfile() so the
        // chain rebuilds against the new bypass mask. testCurveEnabled
        // additionally re-applies the active profile when turned off
        // so the chain doesn't sit flattened post-test-curve.
        eqChain.$referenceMode
            .dropFirst()
            .sink { [weak self] on in self?.audio.setReferenceMode(on) }
            .store(in: &eqChainSubscriptions)
        eqChain.$testCurveEnabled
            .dropFirst()
            .sink { [weak self] on in
                self?.audio.setTestCurveEnabled(on)
                if !on { self?.applyActiveProfile() }
            }
            .store(in: &eqChainSubscriptions)
        eqChain.$testToneEnabled
            .dropFirst()
            .sink { [weak self] on in self?.audio.setTestTone(on) }
            .store(in: &eqChainSubscriptions)
        eqChain.$calibrationToneEnabled
            .dropFirst()
            .sink { [weak self] on in self?.audio.setCalibrationTone(on) }
            .store(in: &eqChainSubscriptions)
        // The per-stage bypass toggles share one handler — each flip rebuilds
        // the chain against the new mask. If the diagnostic test curve is
        // active it owns the cascades, so applyActiveProfile() would no-op and
        // the flip would silently appear to do nothing until the test curve is
        // turned off. A user touching a chain stage is done with the
        // diagnostic, so yield it: clearing testCurveEnabled fires its sink,
        // which restores the profile and applies the new mask immediately.
        let applyOnFlip: (Bool) -> Void = { [weak self] _ in
            guard let self else { return }
            if self.eqChain.testCurveEnabled {
                self.eqChain.testCurveEnabled = false
            } else {
                self.applyActiveProfile()
            }
        }
        eqChain.$eqMasterEnabled.dropFirst().sink(receiveValue: applyOnFlip).store(in: &eqChainSubscriptions)
        eqChain.$autoEQEnabled.dropFirst().sink(receiveValue: applyOnFlip).store(in: &eqChainSubscriptions)
        eqChain.$notchFilterEnabled.dropFirst().sink(receiveValue: applyOnFlip).store(in: &eqChainSubscriptions)
        eqChain.$manualEQEnabled.dropFirst().sink(receiveValue: applyOnFlip).store(in: &eqChainSubscriptions)
        eqChain.$dynamicsEnabled.dropFirst().sink(receiveValue: applyOnFlip).store(in: &eqChainSubscriptions)
        eqChainObserver = eqChain.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // Intentionally NOT rebroadcast — the two SpectrumAnalyzers and
        // the StereoMonitor publish at high rates (FFT cadence ≈ 23 Hz and
        // display-loop 60 Hz respectively). Rebroadcasting either through
        // `audioState.objectWillChange` would re-evaluate every SwiftUI
        // view holding an `@EnvironmentObject AudioState` reference on
        // every publish — i.e. the entire window tree. Canvas / VU
        // views observe the analyzer / monitor directly via @ObservedObject
        // (see `LiveParametricCanvas`, `MonitorSidebar`, `AnalogVUMeter`)
        // so only that subtree pays the cost.
        _ = spectrum
        _ = preSpectrum
        _ = stereoMonitor
        // Throttle to 1 Hz: the tracker publishes objectWillChange on
        // every audio sample (10 Hz, via `currentLevelDBA`), but the
        // popover/sidebar mirror surfaces are slow-moving (whole-
        // percent dose bar, once-per-minute remaining estimate).
        // Rebuilding the popover 10x/sec caused the "all day" label
        // and other Texts to re-rasterize and visibly twitch from
        // sub-pixel positioning differences. `latest: true` keeps the
        // most recent value so we never lose a tick to the throttle.
        // The 1 Hz tracker tick drives only the notification-denial check
        // now — the old dose mirroring is gone (see the dose-observation
        // NOTE near the top of the class); live surfaces subscribe to the
        // tracker themselves.
        trackerObserver = tracker.objectWillChange
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                Task { @MainActor in self?.onTrackerTick() }
            }

        installSleepWakeObservers()

        // Acclimatization ramp (phase3 §5): the effective correction
        // strength moves once per calendar day, so re-apply the active
        // profile when the day changes. One step is ≤ ~0.7 dB on any
        // band — inaudible as a transition (cascade state-zeroing covers
        // the coefficient swap).
        dayChangedObserverToken = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyActiveProfile() }
        }
    }

    deinit {
        if let t = sleepObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(t)
        }
        if let t = wakeObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(t)
        }
        if let t = didBecomeActiveObserverToken {
            NotificationCenter.default.removeObserver(t)
        }
        if let t = sessionResignObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(t)
        }
        if let t = sessionActiveObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(t)
        }
        if let t = dayChangedObserverToken {
            NotificationCenter.default.removeObserver(t)
        }
    }

    /// On sleep the CATap usually keeps its IOProc alive, but the AVAudioEngine
    /// output unit can land in a broken state when the system wakes — silence,
    /// stalled render thread, or a stuck spectrum tap. Tear the engine down on
    /// `.willSleep` and rebuild on `.didWake` so output reattaches cleanly to
    /// whatever device the user is on after wake.
    private func installSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObserverToken = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWillSleep() }
        }
        wakeObserverToken = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleDidWake() }
        }

        // The user can revoke Screen Recording in System Settings while
        // SherlockEQ is running. The IOProc then
        // silently delivers zeros and the rest of our state has no way
        // to know. `didBecomeActiveNotification` fires when the user
        // returns from Settings (the natural moment to re-check), so
        // we ask the tap to re-preflight and flip to `.failed` if
        // permission has dropped.
        didBecomeActiveObserverToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.tap.recheckAudioCapturePermission()
                self.recoverIfAudioFailed()
                await NotificationManager.shared.refreshAuthorizationStatus()
            }
        }

        // Fast user switching. The CATap and its aggregate live in
        // `coreaudiod`, which is system-wide — not per-session — and our tap
        // is created with `mutedWhenTapped`, so it keeps muting the hardware
        // output for whoever is now in front while our session is switched
        // out. Worse, our AVAudioEngine playback belongs to the inactive
        // session and isn't re-injecting the processed signal, so the other
        // user just gets silence until we quit. Tear the whole chain down on
        // `sessionDidResignActive` (releasing the global mute) and rebuild it
        // on `sessionDidBecomeActive`.
        let center2 = NSWorkspace.shared.notificationCenter
        sessionResignObserverToken = center2.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSessionDidResignActive() }
        }
        sessionActiveObserverToken = center2.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSessionDidBecomeActive() }
        }
    }

    /// Our macOS login session was switched out (another user came to the
    /// foreground via fast user switching). Release the system-wide tap so its
    /// `mutedWhenTapped` mute stops silencing the now-foreground user's audio.
    /// Mirror `handleWillSleep`'s busy/up check so a switch landing mid-startup
    /// still resumes when we return.
    private func handleSessionDidResignActive() {
        let tapBusyOrUp: Bool = {
            switch tap.state {
            case .running, .starting: return true
            default:                  return false
            }
        }()
        wasRunningBeforeSessionResign = audio.isRunning || tapBusyOrUp
        guard wasRunningBeforeSessionResign else { return }
        log.info("Session switched out — tearing down audio chain to release tap mute")
        Task { await stopAll() }
    }

    /// Our session is in the foreground again. Rebuild the chain if we tore it
    /// down on the way out.
    private func handleSessionDidBecomeActive() {
        guard wasRunningBeforeSessionResign else { return }
        wasRunningBeforeSessionResign = false
        log.info("Session active again — restarting audio chain")
        Task { await startAll() }
    }

    /// Recovery on app activation — the natural moment something the
    /// user changed (output device, System Settings, or just enough
    /// elapsed time for a wedged HAL to settle) might make a previously
    /// failed start succeed. Two cases:
    ///
    ///   - Tap is `.running` but the AVAudioEngine carries a surfaced
    ///     `lastError`: rebuild the graph in place.
    ///   - Tap itself is `.failed` (e.g. a post-wake transient HAL error
    ///     that exhausted `performStart`'s retries overnight): restart
    ///     the whole chain from scratch.
    ///
    /// `.permissionDenied` is deliberately excluded — that needs the user
    /// to grant access, not a silent retry. Idempotent everywhere else.
    private func recoverIfAudioFailed() {
        if case .failed = tap.state {
            log.info("Tap failed — restarting audio chain on didBecomeActive")
            Task { await startAll() }
            return
        }
        guard audio.lastError != nil, !audio.isRunning else { return }
        guard case .running = tap.state else { return }
        log.info("Engine carries a lastError on didBecomeActive — retrying rebuild")
        scheduleRebuild()
    }

    private func handleWillSleep() {
        // Resume on wake if EITHER the AVAudioEngine was running OR
        // the tap was mid-startup. Previously we only checked
        // `audio.isRunning`, so a sleep landing while `tap.state ==
        // .starting` (e.g. user puts the lid down during the first
        // launch sequence) left `wasRunningBeforeSleep = false` and
        // the half-built tap stranded on wake — the user got silence
        // with no recovery path until they manually restarted from
        // Debug.
        let tapBusyOrUp: Bool = {
            switch tap.state {
            case .running, .starting: return true
            default:                  return false
            }
        }()
        wasRunningBeforeSleep = audio.isRunning || tapBusyOrUp
        if audio.isRunning {
            log.info("System sleeping — stopping AVAudioEngine")
            audio.stop()
        }
    }

    private func handleDidWake() {
        guard wasRunningBeforeSleep else { return }
        wasRunningBeforeSleep = false
        log.info("System woke — rebuilding audio graph")
        if case .running = tap.state {
            scheduleRebuild()
        } else {
            Task { await startAll() }
        }
    }

    /// 1 Hz tracker tick — carries only cross-cutting checks that belong on
    /// AudioState (currently the notification-denial warning at amber dose).
    /// Dose VALUES are no longer mirrored here; see the dose-observation
    /// NOTE near the top of the class.
    /// Consume the staged level, if any. Take-and-clear so a stalled feed
    /// (audio stopped → ingest stops firing) doesn't re-integrate the same
    /// sample forever — matching the old behavior where the callback simply
    /// stopped arriving.
    private func drainDoseLevelSlot() {
        let staged = doseLevelSlot.withLock { slot -> Float? in
            defer { slot = nil }
            return slot
        }
        guard let dba = staged else { return }
        safeListening.update(levelDBA: Double(dba))
    }

    private func onTrackerTick() {
        checkNotificationsDeniedAtAmberDose()
    }

    /// Flips true the first time we warn about denied notifications
    /// while at-or-above amber dose; reset to false when dose drops
    /// back to .safe (e.g. resetDose, midnight rollover) so the
    /// warning fires again at most once per safe-listening cycle.
    private var warnedAboutDeniedNotifications: Bool = false

    /// If safe-listening dose has reached amber/red AND the user has
    /// denied notifications, the threshold warnings will never reach
    /// them through the usual channel. Surface the same warning via
    /// the in-app banner so the safe-listening promise holds even
    /// when the system path is blocked. Shows at most once per cycle.
    private func checkNotificationsDeniedAtAmberDose() {
        if safeListening.doseSeverity == .safe {
            warnedAboutDeniedNotifications = false
            return
        }
        guard !warnedAboutDeniedNotifications else { return }
        let status = NotificationManager.shared.authorizationStatus
        guard status == .denied || status == .notDetermined else { return }
        warnedAboutDeniedNotifications = true
        showNotice(TransientNotice(
            severity: .warning,
            message: "Notifications are off — you won't get safe-listening alerts. Enable them in System Settings → Notifications → SherlockEQ.",
            autoDismissAfter: 12
        ))
    }

    /// Detect a mute left behind by a previous unclean exit and lift it.
    /// Reads the stale marker synchronously (fast UserDefaults) and clears it
    /// immediately so this session's tap start can write its own; the CoreAudio
    /// device read/unmute runs off-main because a wedged HAL can block (see
    /// memory `coreaudio-sync-main-thread-hang`). No-op in the common clean
    /// case — the marker is absent.
    private static func recoverStaleTapMuteIfNeeded() {
        guard let marker = TapMuteSentinel.staleMarker() else { return }
        TapMuteSentinel.clear()
        DispatchQueue.global(qos: .userInitiated).async {
            let uid = SystemVolumeController.defaultOutputDeviceUID()
            let muted = SystemVolumeController.defaultOutputMuted() ?? false
            if TapMuteSentinel.shouldUnmute(marker: marker, currentDeviceUID: uid, currentlyMuted: muted) {
                SystemVolumeController.setDefaultOutputMuted(false)
            }
        }
    }

    func startAll() async {
        // Idempotent: bail if the tap is already up. Both MainWindowView.task
        // and MainPopoverView.task call this on appearance, and the popover
        // re-appears every time MenuBarExtra reopens it. Rebuilding a running
        // tap would deallocate live TapRingBuffers while the IOProc is still
        // writing to them — crash on the audio thread.
        if case .running = tap.state { return }
        if case .starting = tap.state { return }
        await tap.requestPermissionAndStart()
        guard case .running = tap.state else {
            log.error("Tap did not reach .running — skipping AVAudioEngine start")
            return
        }
        scheduleRebuild()
    }

    func stopAll() async {
        audio.teardown()
        await tap.stop()
    }

    /// In-flight trailing-edge rebuild task, plus a pending flag set by any
    /// trigger that arrives while one is running. nil when idle.
    private var rebuildTask: Task<Void, Never>?
    private var rebuildPending = false

    /// Counts consecutive `.sampleRateMismatch` outcomes from `audio.attach`
    /// across rebuild attempts, so a genuinely persistent mismatch surfaces
    /// the error banner instead of retrying forever. Reset to 0 on any
    /// successful attach. Mirrors `SherlockEQAudioEngine.startRetryCount`'s
    /// escalating-backoff shape (200/400/800 ms) for the same class of
    /// post-wake HAL flakiness.
    private var srMismatchRetryCount = 0
    private static let maxSRMismatchRetries = 3

    /// Coalesce + serialize every audio-graph rebuild. A single physical
    /// output-device switch emits a burst of CoreAudio notifications —
    /// default-output change, per-device stream/sample-rate topology changes,
    /// and an AVAudioEngineConfigurationChange — that each independently want
    /// to rebuild. Previously each fired its own detached `Task` calling
    /// `rebuildAudioGraph()`, so two rebuilds could overlap or run out of order
    /// against the tap's own (separately serialized) teardown/rebuild, leaving
    /// the engine attached to half-rebuilt source nodes. Funnelling them all
    /// through one trailing-edge task collapses the burst into a single rebuild
    /// that runs after the tap has settled, always against the latest source
    /// nodes, and guarantees one final pass after the last trigger.
    private func scheduleRebuild() {
        rebuildPending = true
        guard rebuildTask == nil else { return }
        rebuildTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.rebuildTask = nil }
            // No `await` between the final `rebuildPending` read and clearing
            // `rebuildTask`, so a trigger either collapses into this loop or
            // starts a fresh task — a rebuild is never silently dropped.
            while self.rebuildPending {
                self.rebuildPending = false
                self.rebuildAudioGraph()
            }
        }
    }

    private func rebuildAudioGraph() {
        audio.stop()
        spectrum.detached()
        preSpectrum.detached()
        guard let leftSource = tap.leftSourceNode,
              let rightSource = tap.rightSourceNode,
              let format = tap.sourceFormat else {
            log.error("Tap source nodes unavailable — cannot build graph")
            return
        }
        // Engine surfaces the specific reason via `lastError` on failure
        // (format build). Starting anyway would mask it.
        switch audio.attach(
            leftSource: leftSource,
            rightSource: rightSource,
            leftEQCascade: tap.leftEQCascade,
            rightEQCascade: tap.rightEQCascade,
            leftDynamics: tap.leftDynamics,
            rightDynamics: tap.rightDynamics,
            leftAutoEQCascade: tap.leftAutoEQCascade,
            rightAutoEQCascade: tap.rightAutoEQCascade,
            leftAdaptive: tap.leftAdaptive,
            rightAdaptive: tap.rightAdaptive,
            sampleRate: format.sampleRate
        ) {
        case .success:
            srMismatchRetryCount = 0
        case .sampleRateMismatch(let sourceHz, let outputHz):
            // tap.sourceFormat can momentarily lag the output device's real
            // rate right after a sleep/wake or route change — see
            // SherlockEQAudioEngine.attach's doc comment. Retry with the
            // same escalating backoff start()'s transient-HAL-failure path
            // uses, giving the tap's own async device-change handling a
            // window to refresh sourceFormat before the next attempt.
            guard srMismatchRetryCount < Self.maxSRMismatchRetries else {
                log.error("audio.attach: SR mismatch persisted after \(Self.maxSRMismatchRetries) retries — giving up")
                audio.reportPersistentSampleRateMismatch(sourceHz: sourceHz, outputHz: outputHz)
                srMismatchRetryCount = 0
                return
            }
            srMismatchRetryCount += 1
            let delayMS = 200 << (srMismatchRetryCount - 1)   // 200, 400, 800 ms
            log.info("audio.attach: SR mismatch (source \(sourceHz) Hz vs output \(outputHz) Hz) — retry \(self.srMismatchRetryCount)/\(Self.maxSRMismatchRetries) in \(delayMS) ms")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delayMS) * 1_000_000)
                self?.scheduleRebuild()
            }
            return
        case .failed:
            log.error("audio.attach failed — skipping start; lastError preserved")
            return
        }
        audio.start()
        audio.setMasterGain(dB: engineParameters.masterGainDB)
        audio.setLimiterAttack(seconds: engineParameters.limiterAttackMs / 1000.0)
        audio.setLimiterDecay(seconds: engineParameters.limiterDecayMs / 1000.0)
        audio.setLimiterPreGain(dB: engineParameters.limiterPreGainDB)
        applyActiveProfile()
        installSpectrumTap()
        installPreSpectrumTap(tapSR: format.sampleRate)
    }

    private func installSpectrumTap() {
        spectrum.configureForSampleRate(audio.outputSampleRate ?? 48000)
        // Capture strong references to the nonisolated consumers BEFORE the
        // closure literal so the AVAudioEngine tap block doesn't inherit
        // `@MainActor` isolation from this method. Both `ingest` methods
        // are `nonisolated` and realtime-safe; previously the closure was
        // hopping to MainActor on every tap callback (~200/sec).
        let spectrum = self.spectrum
        let stereoMonitor = self.stereoMonitor
        audio.installSpectrumTap { buffer, _ in
            spectrum.ingest(buffer)
            stereoMonitor.ingest(buffer)
        }
    }

    private func installPreSpectrumTap(tapSR: Double) {
        preSpectrum.configureForSampleRate(tapSR)
        let preSpectrum = self.preSpectrum
        tap.preIngest.setCallback { ptr, frames, _ in
            preSpectrum.ingest(monoSamples: ptr, frameCount: frames)
        }
    }

    // MARK: - Settings reset (CLI `reset --settings`)

    /// Restore app preferences and engine knobs to their factory defaults.
    /// Used by the `sherlockeq reset --settings` command. Intentionally
    /// **does not** touch the user's profiles or which profile is active —
    /// "settings" means the app/engine preferences, not saved data.
    ///
    /// Each assignment flows through the existing `@Published` + Combine
    /// bridges, so the engine re-applies and every observing GUI surface
    /// updates live — the same path the Settings screen uses. Login-item
    /// state and the AutoEQ library folder are left alone: those are
    /// system-/user-scoped choices, not transient app preferences.
    func resetSettingsToDefaults() {
        // Engine / output
        engineParameters.masterGainDB = 0
        engineParameters.limiterAttackMs = 12
        engineParameters.limiterDecayMs = 24
        engineParameters.limiterPreGainDB = 0
        calibrationOffsetDBA = 100

        // Transient EQ-chain toggles
        eqChain.referenceMode = false
        eqChain.testCurveEnabled = false
        eqChain.testToneEnabled = false
        eqChain.calibrationToneEnabled = false

        // Per-stage bypass mask — all stages on
        eqChain.eqMasterEnabled = true
        eqChain.autoEQEnabled = true
        eqChain.notchFilterEnabled = true
        eqChain.manualEQEnabled = true
        eqChain.dynamicsEnabled = true

        // UI / shell preferences
        preferences.leftEarColor = AppPreferences.defaultLeftEarColor
        preferences.rightEarColor = AppPreferences.defaultRightEarColor
        preferences.hideFromDockEnabled = true
        preferences.globalReferenceShortcutEnabled = false
        preferences.showDebugInSidebar = false
    }
}
