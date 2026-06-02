import Foundation
import AVFoundation
import Combine
import OSLog

/// AVAudioEngine graph that takes the L/R source nodes from `CATapEngine`,
/// runs each through an independent 10-band `AVAudioUnitEQ`, and sums to stereo
/// output via `mainMixerNode`.
@MainActor
final class AuditumEQAudioEngine: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var referenceMode = false
    @Published private(set) var testCurveEnabled = false

    private let engine = AVAudioEngine()
    private let log = Logger(subsystem: "com.shawnbrown.AuditumEQ", category: "AudioEngine")

    private var leftEQ: AVAudioUnitEQ?
    private var rightEQ: AVAudioUnitEQ?
    private var leftSource: AVAudioSourceNode?
    private var rightSource: AVAudioSourceNode?

    private var tonePlayer: AVAudioPlayerNode?
    private var toneBuffer: AVAudioPCMBuffer?
    @Published private(set) var toneEnabled: Bool = false
    @Published private(set) var outputFormatDescription: String = "—"

    /// Wires up the graph with the L/R source nodes from the tap.
    /// Tears down any prior graph first; safe to call on device change.
    func attach(
        leftSource: AVAudioSourceNode,
        rightSource: AVAudioSourceNode,
        sampleRate: Double
    ) {
        teardownGraph()

        guard let stereoFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        ) else {
            lastError = "Could not build stereo format @ \(sampleRate) Hz"
            return
        }

        let leq = AVAudioUnitEQ(numberOfBands: 10)
        let req = AVAudioUnitEQ(numberOfBands: 10)
        Self.flatten(leq)
        Self.flatten(req)

        engine.attach(leftSource)
        engine.attach(rightSource)
        engine.attach(leq)
        engine.attach(req)

        engine.connect(leftSource, to: leq, format: stereoFormat)
        engine.connect(rightSource, to: req, format: stereoFormat)

        let mixer = engine.mainMixerNode
        // mainMixerNode auto-assigns next input bus for each connect call.
        engine.connect(leq, to: mixer, format: stereoFormat)
        engine.connect(req, to: mixer, format: stereoFormat)

        self.leftSource = leftSource
        self.rightSource = rightSource
        self.leftEQ = leq
        self.rightEQ = req

        leq.bypass = referenceMode
        req.bypass = referenceMode

        log.info("Graph attached @ \(Int(sampleRate)) Hz")
    }

    func start() {
        guard !isRunning else { return }
        guard leftEQ != nil, rightEQ != nil else {
            lastError = "Graph not attached"
            return
        }
        do {
            engine.prepare()
            try engine.start()
            isRunning = true
            lastError = nil
            let f = engine.outputNode.inputFormat(forBus: 0)
            outputFormatDescription = "\(Int(f.sampleRate)) Hz · \(f.channelCount) ch · \(Self.formatLabel(f.commonFormat))"
            log.info("AVAudioEngine started — output expects \(self.outputFormatDescription)")
        } catch {
            isRunning = false
            lastError = "AVAudioEngine.start: \(error.localizedDescription)"
            log.error("AVAudioEngine.start failed: \(error.localizedDescription)")
        }
    }

    private static func formatLabel(_ f: AVAudioCommonFormat) -> String {
        switch f {
        case .pcmFormatFloat32: return "f32"
        case .pcmFormatFloat64: return "f64"
        case .pcmFormatInt16: return "i16"
        case .pcmFormatInt32: return "i32"
        default: return "other"
        }
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        isRunning = false
    }

    func teardown() {
        stop()
        teardownGraph()
    }

    private func teardownGraph() {
        if let ls = leftSource { engine.detach(ls); leftSource = nil }
        if let rs = rightSource { engine.detach(rs); rightSource = nil }
        if let leq = leftEQ { engine.detach(leq); leftEQ = nil }
        if let req = rightEQ { engine.detach(req); rightEQ = nil }
    }

    // MARK: - Controls

    func setReferenceMode(_ on: Bool) {
        referenceMode = on
        leftEQ?.bypass = on
        rightEQ?.bypass = on
    }

    /// Hard-coded asymmetric test curve: L gets +6 dB at 3 kHz, R stays flat.
    /// Listen on headphones — the left ear should sound noticeably brighter on
    /// sibilants/consonants, the right ear unchanged.
    func setTestCurveEnabled(_ on: Bool) {
        testCurveEnabled = on
        guard let leq = leftEQ, let req = rightEQ else { return }
        Self.flatten(leq)
        Self.flatten(req)
        if on {
            let band = leq.bands[0]
            band.filterType = .parametric
            band.frequency = 3000
            band.bandwidth = 0.5    // octaves
            band.gain = 6.0
            band.bypass = false
        }
    }

    /// Diagnostic: route a 440 Hz sine through mainMixer directly, bypassing the
    /// tap → source → EQ chain. If audible → engine→output path is alive (so the
    /// silence is from the upstream chain producing zeros). If silent → output
    /// itself is broken or being muted by the system.
    func setTestTone(_ on: Bool) {
        if on {
            guard tonePlayer == nil else { return }
            let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
            let sr = mixerFormat.sampleRate > 0 ? mixerFormat.sampleRate : 48000
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else { return }
            let frames: AVAudioFrameCount = AVAudioFrameCount(sr)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames

            let freq: Float = 440
            let twoPi: Float = 2 * .pi
            let sampleRate = Float(sr)
            for ch in 0..<Int(format.channelCount) {
                guard let p = buffer.floatChannelData?[ch] else { continue }
                for i in 0..<Int(frames) {
                    p[i] = sin(twoPi * freq * Float(i) / sampleRate) * 0.15
                }
            }

            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            tonePlayer = player
            toneBuffer = buffer
            toneEnabled = true
            log.info("Test tone enabled @ \(Int(sr)) Hz")
        } else {
            if let player = tonePlayer {
                player.stop()
                engine.detach(player)
            }
            tonePlayer = nil
            toneBuffer = nil
            toneEnabled = false
            log.info("Test tone disabled")
        }
    }

    // MARK: - Helpers

    private static func flatten(_ eq: AVAudioUnitEQ) {
        eq.globalGain = 0
        for band in eq.bands {
            band.bypass = true
            band.gain = 0
        }
    }
}
