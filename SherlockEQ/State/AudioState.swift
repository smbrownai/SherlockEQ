import Foundation
import AppKit
import AVFoundation
import Combine
import CoreAudio
import OSLog
import ServiceManagement
import SwiftUI
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

    /// Proxy bindings — view code that reads
    /// `audioState.referenceMode`, `.testCurveEnabled`, etc. keeps
    /// working. New code should depend on EQChainState directly.
    var referenceMode: Bool {
        get { eqChain.referenceMode }
        set { eqChain.referenceMode = newValue }
    }
    var testCurveEnabled: Bool {
        get { eqChain.testCurveEnabled }
        set { eqChain.testCurveEnabled = newValue }
    }
    var testToneEnabled: Bool {
        get { eqChain.testToneEnabled }
        set { eqChain.testToneEnabled = newValue }
    }
    var calibrationToneEnabled: Bool {
        get { eqChain.calibrationToneEnabled }
        set { eqChain.calibrationToneEnabled = newValue }
    }

    /// dBFS level of the calibration tone, exposed so the UI can compute
    /// the offset between the meter reading and the slider value. Always
    /// matches `SherlockEQAudioEngine.calibrationToneDBFS`.
    var calibrationToneLevelDBFS: Float { SherlockEQAudioEngine.calibrationToneDBFS }

    /// Master gain + AUPeakLimiter knobs — see `EngineParameters`.
    /// AudioState sinks each `$value` publisher (in init) and pushes
    /// the result into the engine, so EngineParameters itself knows
    /// nothing about the engine.
    let engineParameters = EngineParameters()

    /// Proxy bindings — existing call sites that read
    /// `audioState.masterGainDB` / `audioState.limiterAttackMs` etc.
    /// keep working. New code should depend on EngineParameters.
    var masterGainDB: Double {
        get { engineParameters.masterGainDB }
        set { engineParameters.masterGainDB = newValue }
    }
    var limiterAttackMs: Double {
        get { engineParameters.limiterAttackMs }
        set { engineParameters.limiterAttackMs = newValue }
    }
    var limiterDecayMs: Double {
        get { engineParameters.limiterDecayMs }
        set { engineParameters.limiterDecayMs = newValue }
    }
    var limiterPreGainDB: Double {
        get { engineParameters.limiterPreGainDB }
        set { engineParameters.limiterPreGainDB = newValue }
    }

    /// App-wide UI / shell preferences (per-ear colors, dock,
    /// launch-at-login, global reference shortcut) — see `AppPreferences`.
    /// Held as a property here so existing call sites keep working via
    /// the proxy bindings below; new code should depend on
    /// `AppPreferences` directly.
    let preferences = AppPreferences()

    /// Proxy bindings so view code that still goes through AudioState
    /// keeps compiling. SwiftUI views observing AudioState re-evaluate
    /// when these change because AudioState republishes
    /// preferences.objectWillChange (wired in init).
    var leftEarColor: Color {
        get { preferences.leftEarColor }
        set { preferences.leftEarColor = newValue }
    }
    var rightEarColor: Color {
        get { preferences.rightEarColor }
        set { preferences.rightEarColor = newValue }
    }
    var hideFromDockEnabled: Bool {
        get { preferences.hideFromDockEnabled }
        set { preferences.hideFromDockEnabled = newValue }
    }
    var launchAtLoginEnabled: Bool {
        get { preferences.launchAtLoginEnabled }
        set { preferences.launchAtLoginEnabled = newValue }
    }
    var globalReferenceShortcutEnabled: Bool {
        get { preferences.globalReferenceShortcutEnabled }
        set { preferences.globalReferenceShortcutEnabled = newValue }
    }
    var showDebugInSidebar: Bool {
        get { preferences.showDebugInSidebar }
        set { preferences.showDebugInSidebar = newValue }
    }

    static let defaultLeftEarColor: Color = AppPreferences.defaultLeftEarColor
    static let defaultRightEarColor: Color = AppPreferences.defaultRightEarColor

    /// User-selected library folder containing AutoEQ correction `.txt`
    /// files. When set, the Headphone-correction picker on Profile Detail
    /// offers a menu listing every `.txt` in this folder in addition to
    /// the "From file…" import. Nil means library disabled; user only sees
    /// the file picker. Stored as a plain path string in UserDefaults
    /// (sandbox is OFF, so we don't need security-scoped bookmarks).
    /// AutoEQ-specific preferences (library folder) — see `AutoEQPreferences`.
    let autoEQPreferences = AutoEQPreferences()

    /// Proxy through to `autoEQPreferences.libraryFolder`. Existing
    /// call sites that read `audioState.autoEQLibraryFolder` keep
    /// working; new code should depend on AutoEQPreferences directly.
    var autoEQLibraryFolder: URL? {
        get { autoEQPreferences.libraryFolder }
        set { autoEQPreferences.libraryFolder = newValue }
    }

    /// Proxy bindings for the per-stage chain toggles. Existing
    /// surfaces (popover power toggle, Settings chain toggles, the
    /// notch-off reminder check) keep working.
    var eqMasterEnabled: Bool {
        get { eqChain.eqMasterEnabled }
        set { eqChain.eqMasterEnabled = newValue }
    }
    var autoEQEnabled: Bool {
        get { eqChain.autoEQEnabled }
        set { eqChain.autoEQEnabled = newValue }
    }
    var notchFilterEnabled: Bool {
        get { eqChain.notchFilterEnabled }
        set { eqChain.notchFilterEnabled = newValue }
    }
    var manualEQEnabled: Bool {
        get { eqChain.manualEQEnabled }
        set { eqChain.manualEQEnabled = newValue }
    }
    var dynamicsEnabled: Bool {
        get { eqChain.dynamicsEnabled }
        set { eqChain.dynamicsEnabled = newValue }
    }
    var hasShownNotchOffReminder: Bool {
        get { eqChain.hasShownNotchOffReminder }
        set { eqChain.hasShownNotchOffReminder = newValue }
    }

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

    /// Throttled mirrors of `safeListening.sessionDose` / `.remainingMinutes`
    /// for views that re-render on every `AudioState` tick. Populated at 1 Hz
    /// from `mirrorTrackerState()` — see the throttle wiring in init.
    ///
    /// Dual-surface warning: any new safe-listening UI logic (e.g. "just
    /// crossed 80%") has to be wired into *both* paths if it needs to be
    /// visible everywhere:
    ///   - The popover and `MonitorSidebar` read these throttled mirrors.
    ///   - `SafeListeningView`, `MenuBarIcon`, and `DebugView` read
    ///     `audioState.safeListening.sessionDose` / `.remainingMinutes`
    ///     directly so they can update faster than 1 Hz.
    /// Threshold/severity helpers belong on `SafeListeningTracker` so both
    /// sides see the same answer.
    @Published var sessionDosePercent: Double = 0
    @Published var remainingMinutes: Double?

    /// Banner state lives on a dedicated `NoticeCenter` so view code
    /// that only cares about notices doesn't pull in the whole audio
    /// pipeline as a dependency. AudioState exposes the same surface
    /// (`userVisibleNotice` / `showNotice` / `dismissNotice`) via
    /// thin proxies below so existing call sites keep working until
    /// they migrate to reading from `noticeCenter` directly.
    let noticeCenter = NoticeCenter()

    /// Proxy: `AudioState.userVisibleNotice` reads through to the
    /// center. SwiftUI views that have AudioState as their
    /// environment object still see changes because AudioState
    /// republishes the center's `objectWillChange` (wired in init).
    var userVisibleNotice: TransientNotice? { noticeCenter.userVisibleNotice }

    /// SPL calibration in dB: the dB SPL the user actually hears when a
    /// 0 dBFS signal plays through the current output device at their
    /// current volume. Drives the dBFS → dBA conversion used by the dose
    /// tracker and the canvas's safety-threshold curve. Default 100 is the
    /// "consumer-headphones at moderate volume" rule of thumb from spec
    /// §5.4 — quieter listeners should set this lower (e.g. 85), louder
    /// listeners higher (e.g. 110). Persisted so the user only calibrates
    /// once per setup.
    @Published var calibrationOffsetDBA: Double = AudioState.loadDouble(
        key: AudioState.calibrationKey,
        default: 100
    ) {
        didSet {
            spectrum.calibrationOffsetDBA = Float(calibrationOffsetDBA)
            preSpectrum.calibrationOffsetDBA = Float(calibrationOffsetDBA)
            UserDefaults.standard.set(calibrationOffsetDBA, forKey: Self.calibrationKey)
        }
    }
    static let calibrationKey = "sherlockeq.calibrationOffsetDBA"

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
    private func autoSwitchProfileIfLinked(deviceID: AudioDeviceID) {
        guard let store = connectedStore,
              let uid = try? CATapEngine.deviceUID(deviceID),
              let match = store.profiles.first(where: { $0.linkedDeviceUID == uid }),
              match.id != activeProfileID else { return }
        log.info("Auto-switching to \(match.name, privacy: .public) for device UID \(uid, privacy: .public)")
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

    /// A bare profile: flat audiogram, no notch / clarity / AutoEQ, Simple-EQ
    /// mode, linked channels. Only the simple shelves + balance ever change.
    private static func makeAnalogProfile() -> HearingProfile {
        var profile = HearingProfile.makeDefault(name: "Analog Control Unit", symbol: "dial.medium.fill")
        profile.eqMode = .simple
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
        guard !testCurveEnabled else { return }
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

    /// Return a copy of `profile` with the appropriate stages zeroed
    /// per the current per-stage toggle state. Master `eqMasterEnabled`
    /// short-circuits everything (mirrors Reference Mode behavior for
    /// the durable toggle). Individual toggles flatten just their
    /// stage so other stages keep working.
    private func applyBypassMask(to profile: HearingProfile) -> HearingProfile {
        var copy = profile
        if !eqMasterEnabled {
            copy.autoEQBands = nil
            copy.autoEQPreampDB = nil
            copy.leftNotch.enabled = false
            copy.rightNotch.enabled = false
            copy.leftEar.bands = []
            copy.rightEar.bands = []
            copy.globalTrimDB = 0
            copy.dynamics = DynamicProcessingSettings()
            return copy
        }
        if !autoEQEnabled {
            copy.autoEQBands = nil
            copy.autoEQPreampDB = nil
        }
        if !notchFilterEnabled {
            copy.leftNotch.enabled = false
            copy.rightNotch.enabled = false
        }
        if !manualEQEnabled {
            copy.leftEar.bands = []
            copy.rightEar.bands = []
        }
        if !dynamicsEnabled {
            copy.dynamics = DynamicProcessingSettings()
        }
        return copy
    }

    private var tapObserver: AnyCancellable?
    private var audioObserver: AnyCancellable?
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
    private var wasRunningBeforeSleep = false
    private let log = Logger(subsystem: "com.shawnbrown.SherlockEQ", category: "AudioState")

    init() {
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

        // Activity meters read live gain deltas from the per-ear dynamic
        // processors (owned by the tap). Provider runs on the main actor
        // (the monitor's 15 Hz timer) — reading the lock-guarded counters
        // is cheap and thread-safe.
        dynamicActivity.deltaMilliDBProvider = { [weak tap] kind, ear in
            guard let tap else { return 0 }
            let proc = ear == .left ? tap.leftDynamics : tap.rightDynamics
            return proc.currentDeltaMilliDB(kind)
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
        // figures the dose tracker integrates match the user's setup.
        spectrum.calibrationOffsetDBA = Float(calibrationOffsetDBA)
        preSpectrum.calibrationOffsetDBA = Float(calibrationOffsetDBA)

        // Spectrum analyzer → dose tracker.
        spectrum.onLevelUpdate = { [weak tracker] dba in
            Task { @MainActor in tracker?.update(levelDBA: Double(dba)) }
        }

        // Re-broadcast child object changes so SwiftUI views observing AudioState
        // refresh when any child's @Published state changes.
        tapObserver = tap.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        audioObserver = audio.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // Rebroadcast so views still observing `audioState.userVisibleNotice`
        // (via the proxy above) re-evaluate when the banner state changes.
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
        // The four per-stage bypass toggles share one handler — each
        // flip rebuilds the chain against the new mask.
        let applyOnFlip: (Bool) -> Void = { [weak self] _ in self?.applyActiveProfile() }
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
        // every publish — i.e. the entire window tree. Canvas / Meters
        // views observe the analyzer / monitor directly via @ObservedObject
        // (see `LiveParametricCanvas`, `MetersView`) so only that subtree
        // pays the cost.
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
        // Views needing finer cadence (Safe Listening's live level
        // meter) read `safeListening` directly, bypassing this mirror.
        trackerObserver = tracker.objectWillChange
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                Task { @MainActor in self?.mirrorTrackerState() }
            }

        installSleepWakeObservers()
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
    }

    /// One-shot recovery for a non-running AVAudioEngine carrying a
    /// surfaced `lastError`. Called when the app becomes active — the
    /// natural moment something the user changed in System Settings
    /// (output device, audio session priority, etc.) might have made
    /// the previously-failed start retryable. Idempotent: if the
    /// engine is already running, no error, or the tap isn't ready,
    /// this is a no-op.
    private func recoverIfAudioFailed() {
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

    /// Mirror the tracker's published values onto the legacy AudioState
    /// properties the popover already binds to (sessionDosePercent etc).
    ///
    /// Each assignment is guarded by an equality check — Swift's
    /// `@Published` fires `objectWillChange` on every assignment
    /// regardless of whether the value changed, which would otherwise
    /// re-render the popover even when nothing observable moved.
    /// Skipping the no-op write keeps SwiftUI quiet on unchanged data.
    private func mirrorTrackerState() {
        let newDose = safeListening.sessionDose
        if sessionDosePercent != newDose { sessionDosePercent = newDose }
        let newRemaining = safeListening.remainingMinutes
        if remainingMinutes != newRemaining { remainingMinutes = newRemaining }
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
        // (format build / SR mismatch). Starting anyway would mask it.
        guard audio.attach(
            leftSource: leftSource,
            rightSource: rightSource,
            leftEQCascade: tap.leftEQCascade,
            rightEQCascade: tap.rightEQCascade,
            leftDynamics: tap.leftDynamics,
            rightDynamics: tap.rightDynamics,
            sampleRate: format.sampleRate
        ) else {
            log.error("audio.attach failed — skipping start; lastError preserved")
            return
        }
        audio.start()
        audio.setMasterGain(dB: masterGainDB)
        audio.setLimiterAttack(seconds: limiterAttackMs / 1000.0)
        audio.setLimiterDecay(seconds: limiterDecayMs / 1000.0)
        audio.setLimiterPreGain(dB: limiterPreGainDB)
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
        tap.preIngest.setCallback { ptr, frames, sr in
            preSpectrum.ingest(monoSamples: ptr, frameCount: frames, sampleRate: sr)
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
        masterGainDB = 0
        limiterAttackMs = 12
        limiterDecayMs = 24
        limiterPreGainDB = 0
        calibrationOffsetDBA = 100

        // Transient EQ-chain toggles
        referenceMode = false
        testCurveEnabled = false
        testToneEnabled = false
        calibrationToneEnabled = false

        // Per-stage bypass mask — all stages on
        eqMasterEnabled = true
        autoEQEnabled = true
        notchFilterEnabled = true
        manualEQEnabled = true
        dynamicsEnabled = true

        // UI / shell preferences
        leftEarColor = AppPreferences.defaultLeftEarColor
        rightEarColor = AppPreferences.defaultRightEarColor
        hideFromDockEnabled = true
        globalReferenceShortcutEnabled = false
        showDebugInSidebar = false
    }
}
