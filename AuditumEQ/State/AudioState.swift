import Foundation
import AppKit
import AVFoundation
import Combine
import CoreAudio
import OSLog
import ServiceManagement
import SwiftUI

/// Single source of truth for audio lifecycle, injected as `@EnvironmentObject`
/// into both popover and main-window hierarchies (Session 4+). Currently wires
/// the tap → AVAudioEngine handoff and exposes the reference-mode / test-curve
/// toggles to the UI.
@MainActor
final class AudioState: ObservableObject {

    @Published private(set) var tap: CATapEngine
    @Published private(set) var audio: AuditumEQAudioEngine
    @Published private(set) var spectrum: SpectrumAnalyzer
    @Published private(set) var preSpectrum: SpectrumAnalyzer
    @Published private(set) var safeListening: SafeListeningTracker

    @Published var referenceMode: Bool = false {
        didSet { audio.setReferenceMode(referenceMode) }
    }

    @Published var testCurveEnabled: Bool = false {
        didSet {
            audio.setTestCurveEnabled(testCurveEnabled)
            // When the test curve is turned off, restore the active profile so
            // the chain doesn't sit flattened.
            if !testCurveEnabled {
                applyActiveProfile()
            }
        }
    }

    @Published var testToneEnabled: Bool = false {
        didSet { audio.setTestTone(testToneEnabled) }
    }

    /// Master output gain, post-limiter. Persists across launches via
    /// UserDefaults; re-applied to the engine on every graph rebuild so a
    /// teardown/reattach cycle doesn't drop the user's setting.
    @Published var masterGainDB: Double = AudioState.loadDouble(key: AudioState.masterGainKey, default: 0) {
        didSet {
            audio.setMasterGain(dB: masterGainDB)
            UserDefaults.standard.set(masterGainDB, forKey: Self.masterGainKey)
        }
    }

    /// AUPeakLimiter parameters — exposed in Settings so users can shape the
    /// limiter's character (snappier attack for transient material, longer
    /// decay for sustained mixes, preGain to push harder into the curve).
    @Published var limiterAttackMs: Double = AudioState.loadDouble(key: AudioState.limiterAttackKey, default: 12.0) {
        didSet {
            audio.setLimiterAttack(seconds: limiterAttackMs / 1000.0)
            UserDefaults.standard.set(limiterAttackMs, forKey: Self.limiterAttackKey)
        }
    }
    @Published var limiterDecayMs: Double = AudioState.loadDouble(key: AudioState.limiterDecayKey, default: 24.0) {
        didSet {
            audio.setLimiterDecay(seconds: limiterDecayMs / 1000.0)
            UserDefaults.standard.set(limiterDecayMs, forKey: Self.limiterDecayKey)
        }
    }
    @Published var limiterPreGainDB: Double = AudioState.loadDouble(key: AudioState.limiterPreGainKey, default: 0) {
        didSet {
            audio.setLimiterPreGain(dB: limiterPreGainDB)
            UserDefaults.standard.set(limiterPreGainDB, forKey: Self.limiterPreGainKey)
        }
    }

    /// Per-ear colors — used everywhere a stereo curve / band / chart is
    /// drawn so users with colorblindness can dial in a palette they can
    /// distinguish. Persisted as #RRGGBB hex via UserDefaults.
    @Published var leftEarColor: Color = AudioState.loadColor(key: AudioState.leftEarColorKey, default: .blue) {
        didSet { UserDefaults.standard.set(leftEarColor.hexString, forKey: Self.leftEarColorKey) }
    }
    @Published var rightEarColor: Color = AudioState.loadColor(key: AudioState.rightEarColorKey, default: .red) {
        didSet { UserDefaults.standard.set(rightEarColor.hexString, forKey: Self.rightEarColorKey) }
    }

    static let defaultLeftEarColor: Color = .blue
    static let defaultRightEarColor: Color = .red

    /// Mirrors `SMAppService.mainApp.status == .enabled`. Setting it
    /// calls `register()` / `unregister()`; if the OS rejects (Login Items
    /// permission denied or similar) the value reverts and the error is
    /// logged so the UI stays in sync with reality.
    /// When true, the app reverts to `.accessory` activation policy on
    /// window close (menu-bar-only, no Dock icon). When false, the Dock
    /// icon persists once the main window has been opened. Trade-off:
    /// `.accessory` keeps the app feeling like a menu-bar utility but
    /// macOS doesn't always redraw the system menu bar reliably on the
    /// `.accessory → .regular` swap; `.regular` permanently avoids that
    /// at the cost of a permanent Dock icon.
    @Published var hideFromDockEnabled: Bool = AudioState.loadBool(key: AudioState.hideFromDockKey, default: true) {
        didSet {
            UserDefaults.standard.set(hideFromDockEnabled, forKey: Self.hideFromDockKey)
            // Turning the toggle off (show in Dock) takes effect right
            // away. Turning it on only kicks in on next window close.
            if !hideFromDockEnabled {
                NSApp.setActivationPolicy(.regular)
            }
        }
    }

    @Published var launchAtLoginEnabled: Bool = (SMAppService.mainApp.status == .enabled) {
        didSet {
            guard launchAtLoginEnabled != oldValue else { return }
            do {
                if launchAtLoginEnabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                log.error("Launch-at-login toggle failed: \(error.localizedDescription, privacy: .public)")
                // Revert without re-triggering didSet (oldValue is the
                // pre-toggle truth; assign on next runloop).
                let revertTo = oldValue
                DispatchQueue.main.async { [weak self] in
                    self?.launchAtLoginEnabled = revertTo
                }
            }
        }
    }

    private static let masterGainKey = "auditumeq.masterGainDB"
    private static let limiterAttackKey = "auditumeq.limiterAttackMs"
    private static let limiterDecayKey = "auditumeq.limiterDecayMs"
    private static let limiterPreGainKey = "auditumeq.limiterPreGainDB"
    private static let leftEarColorKey = "auditumeq.leftEarColorHex"
    private static let rightEarColorKey = "auditumeq.rightEarColorHex"
    private static let hideFromDockKey = "auditumeq.hideFromDock"

    private static func loadDouble(key: String, default defaultValue: Double) -> Double {
        let raw = UserDefaults.standard.object(forKey: key) as? Double
        return raw ?? defaultValue
    }

    private static func loadBool(key: String, default defaultValue: Bool) -> Bool {
        let raw = UserDefaults.standard.object(forKey: key) as? Bool
        return raw ?? defaultValue
    }

    private static func loadColor(key: String, default defaultValue: Color) -> Color {
        guard let hex = UserDefaults.standard.string(forKey: key),
              let color = Color(hexString: hex) else { return defaultValue }
        return color
    }

    /// ID of the currently-active hearing profile. The profile itself lives in
    /// `ProfileStore`; we hold only the ID so the store remains the source of
    /// truth and edits naturally flow through `ProfileStore.save(_:)`.
    @Published var activeProfileID: UUID?

    /// Safe-listening session dose (0…1). Populated by `SafeListeningTracker`
    /// when that lands in Session 10; until then it stays at zero.
    @Published var sessionDosePercent: Double = 0
    @Published var remainingMinutes: Double?
    @Published var currentLeveldBSPL: Double = 0

    func activeProfile(in store: ProfileStore) -> HearingProfile? {
        guard let id = activeProfileID else { return nil }
        return store.profiles.first { $0.id == id }
    }

    /// On first launch, pick the first available profile so the popover and
    /// the audio engine have something to point at.
    func adoptDefaultProfileIfNeeded(from store: ProfileStore) {
        if activeProfileID == nil, let first = store.profiles.first {
            activeProfileID = first.id
        }
    }

    /// Bridge profile state into the audio engine. Subscribes to the active
    /// profile ID and the store's profile array so a change to either
    /// (switching profiles, editing the active profile's audiogram/trim)
    /// re-applies the resulting bands to the EQ nodes.
    func connect(profileStore: ProfileStore) {
        connectedStore = profileStore
        profileSubscriptions.removeAll()

        $activeProfileID
            .dropFirst()
            .sink { [weak self] _ in self?.applyActiveProfile() }
            .store(in: &profileSubscriptions)

        profileStore.$profiles
            .dropFirst()
            .sink { [weak self] _ in self?.applyActiveProfile() }
            .store(in: &profileSubscriptions)

        applyActiveProfile()
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

    /// Look up the active profile in the connected store and push it to the
    /// engine. No-op if no store is connected, no profile is active, the test
    /// curve is currently overriding, or the engine graph isn't attached yet.
    private func applyActiveProfile() {
        guard !testCurveEnabled else { return }
        guard let store = connectedStore,
              let profile = activeProfile(in: store) else { return }
        audio.applyProfile(profile)
    }

    private var tapObserver: AnyCancellable?
    private var audioObserver: AnyCancellable?
    private var spectrumObserver: AnyCancellable?
    private var trackerObserver: AnyCancellable?
    private var profileSubscriptions: Set<AnyCancellable> = []
    private weak var connectedStore: ProfileStore?
    private var sleepObserverToken: NSObjectProtocol?
    private var wakeObserverToken: NSObjectProtocol?
    private var wasRunningBeforeSleep = false
    private let log = Logger(subsystem: "com.shawnbrown.AuditumEQ", category: "AudioState")

    init() {
        let tap = CATapEngine()
        let audio = AuditumEQAudioEngine()
        let spectrum = SpectrumAnalyzer()
        let preSpectrum = SpectrumAnalyzer()
        let tracker = SafeListeningTracker()
        self.tap = tap
        self.audio = audio
        self.spectrum = spectrum
        self.preSpectrum = preSpectrum
        self.safeListening = tracker

        tap.onOutputDeviceChanged = { [weak self] deviceID in
            Task { @MainActor in
                self?.rebuildAudioGraph()
                self?.autoSwitchProfileIfLinked(deviceID: deviceID)
            }
        }

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
        spectrumObserver = spectrum.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        trackerObserver = tracker.objectWillChange.sink { [weak self] _ in
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
    }

    private func handleWillSleep() {
        wasRunningBeforeSleep = audio.isRunning
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
            rebuildAudioGraph()
        } else {
            Task { await startAll() }
        }
    }

    /// Mirror the tracker's published values onto the legacy AudioState
    /// properties the popover already binds to (sessionDosePercent etc).
    private func mirrorTrackerState() {
        sessionDosePercent = safeListening.sessionDose
        remainingMinutes = safeListening.remainingMinutes
        currentLeveldBSPL = safeListening.currentLevelDBA
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
        rebuildAudioGraph()
    }

    func stopAll() {
        audio.teardown()
        tap.stop()
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
        audio.attach(
            leftSource: leftSource,
            rightSource: rightSource,
            sampleRate: format.sampleRate
        )
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
        audio.installSpectrumTap { [weak spectrum] buffer, _ in
            spectrum?.ingest(buffer)
        }
    }

    private func installPreSpectrumTap(tapSR: Double) {
        preSpectrum.configureForSampleRate(tapSR)
        tap.preIngest.callback = { [weak preSpectrum] ptr, frames, sr in
            preSpectrum?.ingest(monoSamples: ptr, frameCount: frames, sampleRate: sr)
        }
    }
}
