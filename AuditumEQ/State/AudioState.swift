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

    @Published var referenceMode: Bool = false {
        didSet { audio.setReferenceMode(referenceMode) }
    }

    @Published var testCurveEnabled: Bool = false {
        didSet { audio.setTestCurveEnabled(testCurveEnabled) }
    }

    @Published var testToneEnabled: Bool = false {
        didSet { audio.setTestTone(testToneEnabled) }
    }

    private var tapObserver: AnyCancellable?
    private var audioObserver: AnyCancellable?
    private let log = Logger(subsystem: "com.shawnbrown.AuditumEQ", category: "AudioState")

    init() {
        let tap = CATapEngine()
        let audio = AuditumEQAudioEngine()
        self.tap = tap
        self.audio = audio

        tap.onOutputDeviceChanged = { [weak self] _ in
            Task { @MainActor in self?.rebuildAudioGraph() }
        }

        // Re-broadcast child object changes so SwiftUI views observing AudioState
        // refresh when either engine's @Published state changes.
        tapObserver = tap.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        audioObserver = audio.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
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
    }
}
