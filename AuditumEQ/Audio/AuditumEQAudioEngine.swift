import Foundation
import AVFoundation
import AudioToolbox
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
    private var limiter: AVAudioUnitEffect?

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

        // Sine tone generator — direct path to mainMixer, no EQ.
        if let toneNode = toneGenerator.makeSourceNode(sampleRate: sampleRate) {
            engine.attach(toneNode)
            engine.connect(toneNode, to: engine.mainMixerNode, format: tapFormat)
            toneSourceNode = toneNode
        }

        let outRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let mixer = engine.mainMixerNode

        // Output limiter — Apple's AUPeakLimiter. Catches peaks past 0 dBFS
        // without coloring program material, so band sums that overshoot get
        // brick-walled cleanly instead of clipping into the output stage.
        let limiterDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let lim = AVAudioUnitEffect(audioComponentDescription: limiterDesc)
        engine.attach(lim)
        self.limiter = lim

        if outRate > 0 && Int(outRate.rounded()) != Int(sampleRate.rounded()),
           let outFormat = AVAudioFormat(standardFormatWithSampleRate: outRate, channels: 2) {
            let bridge = AVAudioMixerNode()
            engine.attach(bridge)
            engine.connect(leq, to: bridge, format: tapFormat)
            engine.connect(req, to: bridge, format: tapFormat)
            engine.connect(bridge, to: lim, format: tapFormat)
            engine.connect(lim, to: mixer, format: outFormat)
            self.sampleRateBridge = bridge
            sampleRateMismatchWarning = "Tap \(Int(sampleRate)) Hz ≠ output \(Int(outRate)) Hz — audio quality degraded until manual resampler lands."
            log.info("Graph attached — tap \(Int(sampleRate)) Hz, output \(Int(outRate)) Hz (SR-bridged, degraded)")
        } else {
            // AUPeakLimiter has a single input bus, so we can't connect leq
            // and req directly to it — the second connection silently
            // overrides the first and kills the L chain. Sum L+R through an
            // explicit mixer first.
            let sumMixer = AVAudioMixerNode()
            engine.attach(sumMixer)
            engine.connect(leq, to: sumMixer, format: tapFormat)
            engine.connect(req, to: sumMixer, format: tapFormat)
            engine.connect(sumMixer, to: lim, format: tapFormat)
            engine.connect(lim, to: mixer, format: tapFormat)
            self.sampleRateBridge = sumMixer
            sampleRateMismatchWarning = nil
            log.info("Graph attached — \(Int(sampleRate)) Hz end-to-end (sum + limiter inline)")
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
        removeSpectrumTap()
        if engine.isRunning { engine.stop() }
        isRunning = false
    }

    func teardown() {
        stop()
        teardownGraph()
    }

    private var spectrumTapInstalled = false

    /// Tone Finder's sine generator. Attached to mainMixer directly so the
    /// reference pitch isn't colored by the user's per-ear EQ — they need
    /// to hear the same tone the comparison process expects.
    let toneGenerator = SineToneGenerator()
    private var toneSourceNode: AVAudioSourceNode?

    /// The sample rate the engine's output is running at — what `mainMixerNode`
    /// emits and therefore what the spectrum tap sees. nil if the engine isn't
    /// running yet.
    var outputSampleRate: Double? {
        let rate = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        return rate > 0 ? rate : nil
    }

    /// Install a buffer tap on `mainMixerNode` so a downstream analyzer can
    /// pull post-EQ PCM frames. The closure runs on the audio render thread;
    /// keep work realtime-safe (memcpy at most).
    func installSpectrumTap(
        bufferSize: AVAudioFrameCount = 1024,
        _ ingest: @escaping (AVAudioPCMBuffer, Double) -> Void
    ) {
        guard !spectrumTapInstalled else { return }
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            ingest(buffer, format.sampleRate)
        }
        spectrumTapInstalled = true
        log.info("Spectrum tap installed (\(Int(format.sampleRate)) Hz, buffer \(bufferSize))")
    }

    func removeSpectrumTap() {
        guard spectrumTapInstalled else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        spectrumTapInstalled = false
    }


    private func teardownGraph() {
        if let ls = leftSource { engine.detach(ls); leftSource = nil }
        if let rs = rightSource { engine.detach(rs); rightSource = nil }
        if let leq = leftEQ { engine.detach(leq); leftEQ = nil }
        if let req = rightEQ { engine.detach(req); rightEQ = nil }
        if let b = sampleRateBridge { engine.detach(b); sampleRateBridge = nil }
        if let l = limiter { engine.detach(l); limiter = nil }
        if let t = toneSourceNode { engine.detach(t); toneSourceNode = nil }
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

        // Notch is shared across ears (spec §5.3) — pretend it's an extra
        // band tacked onto each per-ear chain so the existing apply() works.
        let leftBands = profile.leftEar.bands + Self.notchAsBand(profile.notch)
        let rightBands = profile.rightEar.bands + Self.notchAsBand(profile.notch)

        Self.apply(bands: leftBands, to: leq)
        Self.apply(bands: rightBands, to: req)

        let (leftPanDB, rightPanDB) = Self.balanceDeltaDB(profile.balance)
        leq.globalGain = Float(profile.globalTrimDB + leftPanDB)
        req.globalGain = Float(profile.globalTrimDB + rightPanDB)

        leq.bypass = referenceMode
        req.bypass = referenceMode

        log.info("Applied profile \(profile.name, privacy: .public) — L:\(leftBands.count) bands, R:\(rightBands.count) bands, trim:\(profile.globalTrimDB) dB, balance:\(profile.balance, format: .fixed(precision: 2)), notch:\(profile.notch.enabled ? "on" : "off")")
    }

    /// Linear-pan attenuation converted to dB so it can ride along with the
    /// per-ear EQ globalGain. AVAudioUnitEQ doesn't expose AVAudioMixing.volume,
    /// so we can't do it as a send level — folding into globalGain is the same
    /// effect with one fewer node in the chain. Full-opposite caps at -60 dB so
    /// log10 doesn't blow up at zero.
    static func balanceDeltaDB(_ balance: Double) -> (left: Double, right: Double) {
        let b = max(-1, min(1, balance))
        let leftLinear  = b <= 0 ? 1.0 : max(0.001, 1.0 - b)
        let rightLinear = b >= 0 ? 1.0 : max(0.001, 1.0 + b)
        return (20 * log10(leftLinear), 20 * log10(rightLinear))
    }

    private static func notchAsBand(_ notch: TinnitusNotch) -> [EQBand] {
        guard notch.enabled else { return [] }
        return [
            EQBand(
                frequencyHz: notch.frequencyHz,
                gaindB: notch.depthdB,
                bandwidth: 1.0 / max(notch.qWidth.qValue, 0.1),
                filterType: .notch,
                enabled: true
            )
        ]
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
        case .bandPass:   return .bandPass
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
