import Foundation
import AVFoundation
import Combine
import CoreAudio
import OSLog

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

        tap.onOutputDeviceChanged = { [weak self] _ in
            Task { @MainActor in self?.rebuildAudioGraph() }
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
    }

    /// Mirror the tracker's published values onto the legacy AudioState
    /// properties the popover already binds to (sessionDosePercent etc).
    private func mirrorTrackerState() {
        sessionDosePercent = safeListening.sessionDose
        remainingMinutes = safeListening.remainingMinutes
        currentLeveldBSPL = safeListening.currentLevelDBA
    }

    func startAll() async {
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
