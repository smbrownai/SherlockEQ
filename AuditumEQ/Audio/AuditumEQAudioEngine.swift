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
    /// Non-nil when tap rate differs from output rate — audio quality is
    /// degraded by AVAudioMixerNode's internal resampler on this path.
    /// Cleared when rates match.
    @Published private(set) var sampleRateMismatchWarning: String?

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

    private var sampleRateBridge: AVAudioMixerNode?

    /// Wires up the graph with the L/R source nodes from the tap.
    /// Tears down any prior graph first; safe to call on device change.
    ///
    /// Sample-rate handling: when the tap's rate (driven by the system's default
    /// output device at tap-creation time) differs from the engine's outputNode
    /// rate (driven by the *current* default output device, which can change),
    /// `mainMixerNode`'s built-in conversion produces audible distortion on at
    /// least the 3.5mm/USB-C path. Inserting an explicit `AVAudioMixerNode`
    /// downstream of the EQs whose connection to mainMixer is at the output's
    /// rate confines the SR conversion to a dedicated node, which sounds clean.
    func attach(
        leftSource: AVAudioSourceNode,
        rightSource: AVAudioSourceNode,
        sampleRate: Double
    ) {
        teardownGraph()

        guard let tapFormat = AVAudioFormat(
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

        engine.connect(leftSource, to: leq, format: tapFormat)
        engine.connect(rightSource, to: req, format: tapFormat)

        let outRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let mixer = engine.mainMixerNode

        if outRate > 0 && Int(outRate.rounded()) != Int(sampleRate.rounded()),
           let outFormat = AVAudioFormat(standardFormatWithSampleRate: outRate, channels: 2) {
            // SR mismatch — insert a bridging mixer so the conversion lives in
            // a dedicated node. Note: this only confines the bad resampling, it
            // doesn't fix it. The real fix is a manual AVAudioConverter-based
            // resampler in the source-node render block; tracked for follow-up.
            let bridge = AVAudioMixerNode()
            engine.attach(bridge)
            engine.connect(leq, to: bridge, format: tapFormat)
            engine.connect(req, to: bridge, format: tapFormat)
            engine.connect(bridge, to: mixer, format: outFormat)
            self.sampleRateBridge = bridge
            sampleRateMismatchWarning = "Tap \(Int(sampleRate)) Hz ≠ output \(Int(outRate)) Hz — audio quality degraded until manual resampler lands."
            log.info("Graph attached — tap \(Int(sampleRate)) Hz, output \(Int(outRate)) Hz (SR-bridged, degraded)")
        } else {
            // Matched SR end-to-end — direct, no bridge needed.
            engine.connect(leq, to: mixer, format: tapFormat)
            engine.connect(req, to: mixer, format: tapFormat)
            sampleRateMismatchWarning = nil
            log.info("Graph attached — \(Int(sampleRate)) Hz end-to-end")
        }

        self.leftSource = leftSource
        self.rightSource = rightSource
        self.leftEQ = leq
        self.rightEQ = req

        leq.bypass = referenceMode
        req.bypass = referenceMode
    }

    func start() {
        guard !isRunning else { return }
        guard leftSource != nil, rightSource != nil else {
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
        if let b = sampleRateBridge { engine.detach(b); sampleRateBridge = nil }
    }

    // MARK: - Controls

    func setReferenceMode(_ on: Bool) {
        referenceMode = on
        leftEQ?.bypass = on
        rightEQ?.bypass = on
    }

    /// Hard-coded asymmetric test curve: L gets +6 dB at 3 kHz, R stays flat.
    /// When enabled, overrides any active hearing-profile bands; when disabled
    /// the caller (AudioState) reapplies the active profile so we don't leave
    /// the chain flattened.
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

    /// Apply a hearing profile's per-ear bands + global trim to the chain.
    /// Excess band slots beyond the profile's band count are flattened and
    /// bypassed. Reference mode is preserved (we don't fight the bypass flag).
    /// Has no effect if the graph isn't attached yet (CATap permission denied,
    /// device not ready, etc.) — `attach()` calls this when the graph comes up.
    func applyProfile(_ profile: HearingProfile) {
        guard let leq = leftEQ, let req = rightEQ else { return }

        // Global trim — clamped to AVAudioUnitEQ's ±96 dB but profile is ±12.
        let trim = Float(profile.globalTrimDB)
        leq.globalGain = trim
        req.globalGain = trim

        Self.apply(bands: profile.leftEar.bands, to: leq)
        Self.apply(bands: profile.rightEar.bands, to: req)

        // Reference mode bypass is independent of band content; reassert.
        leq.bypass = referenceMode
        req.bypass = referenceMode

        log.info("Applied profile \(profile.name, privacy: .public) — L:\(profile.leftEar.bands.count) bands, R:\(profile.rightEar.bands.count) bands, trim:\(profile.globalTrimDB) dB")
    }

    private static func apply(bands profileBands: [EQBand], to eq: AVAudioUnitEQ) {
        let slots = eq.bands.count
        for i in 0..<slots {
            let node = eq.bands[i]
            if i < profileBands.count {
                let b = profileBands[i]
                node.filterType = avFilterType(from: b.filterType)
                node.frequency = Float(b.frequencyHz)
                node.gain = Float(b.gaindB)
                node.bandwidth = Float(b.bandwidth)
                node.bypass = !b.enabled
            } else {
                node.bypass = true
                node.gain = 0
            }
        }
    }

    private static func avFilterType(from t: EQFilterType) -> AVAudioUnitEQFilterType {
        switch t {
        case .parametric: return .parametric
        case .lowShelf:   return .lowShelf
        case .highShelf:  return .highShelf
        case .notch:      return .bandStop
        case .lowPass:    return .lowPass
        case .highPass:   return .highPass
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
