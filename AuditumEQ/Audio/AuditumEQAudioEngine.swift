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

    private let engine = AVAudioEngine()
    private let log = Logger(subsystem: "com.shawnbrown.AuditumEQ", category: "AudioEngine")

    /// Full per-ear EQ runs as a manual biquad cascade inside the
    /// source-node render block (owned by `CATapEngine`). One cascade
    /// per ear, carrying AutoEQ headphone correction + profile bands +
    /// tinnitus notch + global trim. Replaces the previous
    /// `leftAutoEQ` + `leftEQ` (and right) AVAudioUnitEQ pair, both of
    /// which introduced cross-channel content even with mono-on-one-
    /// channel input. References stored at attach time so
    /// `applyProfile` can push new coefficients on profile changes.
    private weak var leftEQCascade: BiquadCascade?
    private weak var rightEQCascade: BiquadCascade?
    /// Sample rate the cascades' coefficients were computed at — kept
    /// so `applyProfile` can recompute against the right Nyquist on
    /// rebuilds (e.g. output-device switch with a different rate).
    private var tapSampleRate: Double = 48000
    /// Per-ear balance stages between `{l,r}eq` and `sumMixer`. Drives
    /// the stereo-balance attenuation via `outputVolume` (linear, in
    /// the AVAudioMixing protocol) instead of `{l,r}eq.globalGain`,
    /// which appeared to leak ~45 dB at extreme attenuations. See
    /// `avaudiounit-eq-extreme-attenuation-leak.md`.
    private var leftBalanceMixer: AVAudioMixerNode?
    private var rightBalanceMixer: AVAudioMixerNode?
    private var leftSource: AVAudioSourceNode?
    private var rightSource: AVAudioSourceNode?

    private var tonePlayer: AVAudioPlayerNode?
    private var toneBuffer: AVAudioPCMBuffer?
    @Published private(set) var toneEnabled: Bool = false
    @Published private(set) var outputFormatDescription: String = "—"

    private var sampleRateBridge: AVAudioMixerNode?
    private var limiter: AVAudioUnitEffect?
    /// 1-band-bypassed AVAudioUnitEQ used purely as a gain stage. Its
    /// `globalGain` (-96…+24 dB range) gives reliable dB control where
    /// `mainMixerNode.outputVolume` silently no-ops on this graph.
    private var masterGainStage: AVAudioUnitEQ?
    private var masterGainDB: Double = 0

    /// Wires up the graph with the L/R source nodes from the tap.
    /// Tears down any prior graph first; safe to call on device change.
    ///
    /// Sample-rate handling: the `sampleRate` passed in is the output
    /// device's nominal rate (which is also the rate the aggregate's
    /// drift-compensated IOProc delivers). The engine's outputNode rate
    /// matches, so the graph is uniform end-to-end and no bridge / SRC
    /// node is required. See memory `audio-engine-sr-mismatch`.
    func attach(
        leftSource: AVAudioSourceNode,
        rightSource: AVAudioSourceNode,
        leftEQCascade: BiquadCascade,
        rightEQCascade: BiquadCascade,
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
        self.tapSampleRate = sampleRate
        self.leftEQCascade = leftEQCascade
        self.rightEQCascade = rightEQCascade

        engine.attach(leftSource)
        engine.attach(rightSource)

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

        let gainStage = AVAudioUnitEQ(numberOfBands: 1)
        gainStage.bands[0].bypass = true
        gainStage.globalGain = Float(masterGainDB)
        engine.attach(gainStage)
        self.masterGainStage = gainStage

        if outRate > 0 && Int(outRate.rounded()) != Int(sampleRate.rounded()) {
            // Source-node format is now stamped at the output device's
            // nominal rate (in `CATapEngine.buildTapAndAggregate`), and the
            // aggregate's drift comp delivers that same rate to the IOProc
            // — so this branch shouldn't be reachable in normal operation.
            // Logging if it ever fires would catch a regression (e.g. tap
            // built before output device changed without rebuild).
            log.error("Unexpected SR mismatch: source \(Int(sampleRate)) Hz vs output \(Int(outRate)) Hz — graph rebuild needed")
        }

        // AUPeakLimiter has a single input bus, so we
        // can't connect the two source nodes directly to it — the second
        // connection silently overrides the first and kills the L chain.
        // Sum L+R through an explicit mixer first.
        //
        // Per-ear balance mixers sit between source nodes and sumMixer.
        // The AVAudioMixing protocol's `outputVolume` gives clean linear
        // attenuation on the bus, bypassing whatever cross-channel
        // handling sumMixer / mainMixerNode does on stereo input at
        // their defaults. Folding balance into upstream `globalGain`
        // worked at small offsets but leaked ~45 dB at full pan.
        //
        // EQ (AutoEQ + profile bands + notch + trim) runs as a biquad
        // cascade inside the source-node render block — owned by
        // CATapEngine, configured from `applyProfile`. No AVAudioUnitEQ
        // stage in this graph any more.
        let lBal = AVAudioMixerNode()
        let rBal = AVAudioMixerNode()
        engine.attach(lBal)
        engine.attach(rBal)
        self.leftBalanceMixer = lBal
        self.rightBalanceMixer = rBal

        let sumMixer = AVAudioMixerNode()
        engine.attach(sumMixer)
        engine.connect(leftSource, to: lBal, format: tapFormat)
        engine.connect(rightSource, to: rBal, format: tapFormat)
        engine.connect(lBal, to: sumMixer, format: tapFormat)
        engine.connect(rBal, to: sumMixer, format: tapFormat)
        engine.connect(sumMixer, to: lim, format: tapFormat)
        engine.connect(lim, to: gainStage, format: tapFormat)
        engine.connect(gainStage, to: mixer, format: tapFormat)
        self.sampleRateBridge = sumMixer
        log.info("Graph attached — \(Int(sampleRate)) Hz end-to-end (balance mixers + limiter + gain stage inline; EQ in render block)")

        self.leftSource = leftSource
        self.rightSource = rightSource

        // EQ cascades bypass when the user wants to hear raw signal.
        leftEQCascade.setBypassed(referenceMode)
        rightEQCascade.setBypassed(referenceMode)
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
    ///
    /// We tap `mainMixerNode` rather than `masterGainStage` (one node
    /// upstream) because the meter should reflect what the listener
    /// actually hears. A diagnostic during the balance-leak work
    /// surfaced ~−30 dB cross-channel content at `masterGainStage`
    /// even with the per-ear balance mixer fully muted, but the same
    /// content reads near the floor at `mainMixerNode` and is
    /// audibly silent at the speakers — `mainMixerNode` (or the
    /// output-device format conversion at its boundary) is scrubbing
    /// the residual. Tapping there matches the listener experience.
    /// The internal residual is real but not user-facing; worth
    /// chasing only if it grows or starts bleeding to the output.
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
        if let lb = leftBalanceMixer { engine.detach(lb); leftBalanceMixer = nil }
        if let rb = rightBalanceMixer { engine.detach(rb); rightBalanceMixer = nil }
        if let b = sampleRateBridge { engine.detach(b); sampleRateBridge = nil }
        if let l = limiter { engine.detach(l); limiter = nil }
        if let g = masterGainStage { engine.detach(g); masterGainStage = nil }
        // EQ cascades are owned by CATapEngine — clear them to
        // unity-and-bypassed so any audio that flows during teardown
        // doesn't pick up a stale coefficient set, then drop our refs.
        leftEQCascade?.setBands([], preampDB: 0, sampleRate: tapSampleRate)
        rightEQCascade?.setBands([], preampDB: 0, sampleRate: tapSampleRate)
        leftEQCascade?.setBypassed(true)
        rightEQCascade?.setBypassed(true)
        leftEQCascade = nil
        rightEQCascade = nil
        if let t = toneSourceNode { engine.detach(t); toneSourceNode = nil }
    }

    // MARK: - Controls

    func setReferenceMode(_ on: Bool) {
        referenceMode = on
        // EQ cascades carry AutoEQ + profile bands + notch + trim —
        // a single bypass toggle takes the whole stack out of the path
        // so the user hears the truly-unprocessed source signal.
        leftEQCascade?.setBypassed(on)
        rightEQCascade?.setBypassed(on)
    }

    /// Master output gain applied post-limiter via a dedicated AVAudioUnitEQ
    /// gain stage. Clamped to ≤ +12 dB so the limiter still has headroom; the
    /// gain stage's globalGain spans -96…+24 dB, so -60 dB is effectively
    /// inaudible without triggering any silent no-op behavior.
    func setMasterGain(dB: Double) {
        let clamped = max(-60, min(12, dB))
        masterGainDB = clamped
        masterGainStage?.globalGain = Float(clamped)
    }

    /// AUPeakLimiter parameter setters. Param IDs and ranges come from
    /// `AudioUnitParameters.h`:
    /// - attack:  0.001 … 0.03 s  (default 0.012)
    /// - decay:   0.001 … 0.06 s  (default 0.024)
    /// - preGain: -40 … +40 dB     (default 0)
    func setLimiterAttack(seconds: Double) {
        guard let au = limiter?.audioUnit else { return }
        let v = Float(max(0.001, min(0.03, seconds)))
        AudioUnitSetParameter(au, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, v, 0)
    }

    func setLimiterDecay(seconds: Double) {
        guard let au = limiter?.audioUnit else { return }
        let v = Float(max(0.001, min(0.06, seconds)))
        AudioUnitSetParameter(au, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, v, 0)
    }

    func setLimiterPreGain(dB: Double) {
        guard let au = limiter?.audioUnit else { return }
        let v = Float(max(-40, min(40, dB)))
        AudioUnitSetParameter(au, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, v, 0)
    }

    /// Hard-coded asymmetric test curve: L gets +6 dB at 3 kHz, R stays flat.
    /// When enabled, overrides any active hearing-profile bands; when disabled
    /// the caller (AudioState) reapplies the active profile so we don't leave
    /// the chain flattened.
    func setTestCurveEnabled(_ on: Bool) {
        testCurveEnabled = on
        if on {
            // Diagnostic curve: a single +6 dB parametric peak at 3 kHz
            // — easy to hear, easy to compare to a reference. Pushed
            // directly to both cascades, overriding whatever the active
            // profile last installed. AudioState re-applies the profile
            // when the user turns this off.
            let testBand = EQBand(
                frequencyHz: 3000,
                gaindB: 6,
                bandwidth: 1.0,
                filterType: .parametric,
                enabled: true
            )
            leftEQCascade?.setBands([testBand], preampDB: 0, sampleRate: tapSampleRate)
            rightEQCascade?.setBands([testBand], preampDB: 0, sampleRate: tapSampleRate)
            leftEQCascade?.setBypassed(false)
            rightEQCascade?.setBypassed(false)
        } else {
            leftEQCascade?.setBands([], preampDB: 0, sampleRate: tapSampleRate)
            rightEQCascade?.setBands([], preampDB: 0, sampleRate: tapSampleRate)
        }
    }

    /// Apply a hearing profile's per-ear bands + global trim to the chain.
    /// Folds AutoEQ + profile bands + tinnitus notch + global trim into
    /// a single biquad cascade per ear, processed in the source-node
    /// render block. Reference mode is preserved.
    /// Has no effect if the graph isn't attached yet (CATap permission denied,
    /// device not ready, etc.) — `attach()` calls this when the graph comes up.
    func applyProfile(_ profile: HearingProfile) {
        // Balance rides on the per-ear AVAudioMixerNode's `outputVolume`
        // (linear, in the AVAudioMixing protocol). A dedicated mixer
        // stage with `outputVolume` sidesteps the cross-channel handling
        // that re-introduces signal from an attenuated bus — when the
        // bus volume goes to 0, no signal reaches the sum.
        let (leftLinear, rightLinear) = Self.balanceLinear(profile.balance)
        leftBalanceMixer?.outputVolume = Float(leftLinear)
        rightBalanceMixer?.outputVolume = Float(rightLinear)
        log.info("Balance — L bus \(leftLinear, format: .fixed(precision: 3)), R bus \(rightLinear, format: .fixed(precision: 3)); trim \(profile.globalTrimDB, format: .fixed(precision: 2)) dB; balance \(profile.balance, format: .fixed(precision: 2))")

        // Combined per-ear EQ stack:
        //   1. AutoEQ headphone-correction bands (same for both ears —
        //      AutoEQ files describe a stereo pair, not per-cup)
        //   2. Profile bands for this ear
        //   3. Tinnitus notch (shared across ears, spec §5.3)
        //
        // Combined preamp = AutoEQ preamp + profile global trim. All of
        // it goes through the BiquadCascade so the L and R signal paths
        // stay physically separate. Replaces the previous {leftAutoEQ,
        // leftEQ} AVAudioUnitEQ pair (and right), which leaked cross-
        // channel content even with mono-on-one-channel input.
        let autoBands = profile.autoEQBands ?? []
        // Per-ear notch — Tinnitus Notch UI lets the user dial in two
        // independent notches (e.g. for unilateral tinnitus) when
        // `separateNotch` is on. When off, the UI keeps the two in
        // sync, so leftNotch and rightNotch carry the same values.
        let leftNotchBand = Self.notchAsBand(profile.leftNotch)
        let rightNotchBand = Self.notchAsBand(profile.rightNotch)
        let combinedLeftBands = autoBands + profile.leftEar.bands + leftNotchBand
        let combinedRightBands = autoBands + profile.rightEar.bands + rightNotchBand
        let combinedPreampDB = (profile.autoEQPreampDB ?? 0) + profile.globalTrimDB

        leftEQCascade?.setBands(combinedLeftBands, preampDB: combinedPreampDB, sampleRate: tapSampleRate)
        rightEQCascade?.setBands(combinedRightBands, preampDB: combinedPreampDB, sampleRate: tapSampleRate)
        leftEQCascade?.setBypassed(referenceMode)
        rightEQCascade?.setBypassed(referenceMode)

        let notchDescription: String = {
            switch (profile.leftNotch.enabled, profile.rightNotch.enabled) {
            case (false, false): return "off"
            case (true, false):  return "L only"
            case (false, true):  return "R only"
            case (true, true):
                return profile.leftNotch.frequencyHz == profile.rightNotch.frequencyHz
                    ? "both \(Int(profile.leftNotch.frequencyHz)) Hz"
                    : "L \(Int(profile.leftNotch.frequencyHz)) Hz, R \(Int(profile.rightNotch.frequencyHz)) Hz"
            }
        }()
        log.info("Applied profile \(profile.name, privacy: .public) — L:\(combinedLeftBands.count) bands, R:\(combinedRightBands.count) bands, preamp+trim:\(combinedPreampDB) dB, balance:\(profile.balance, format: .fixed(precision: 2)), notch:\(notchDescription, privacy: .public), autoEQ:\(profile.autoEQName ?? "none", privacy: .public)")
    }

    /// Linear-domain balance attenuation fed to the per-ear
    /// `AVAudioMixerNode.outputVolume`. balance = 0 leaves both buses
    /// at unity; positive values attenuate the left bus, negative
    /// values the right. Snaps cleanly to 0 at the extremes since
    /// `outputVolume = 0` truly mutes the bus.
    static func balanceLinear(_ balance: Double) -> (left: Double, right: Double) {
        let b = max(-1, min(1, balance))
        // Volume snaps cleanly to 0 at the extremes — no need for the 0.001
        // floor that `globalGain` required to avoid log10(0).
        let leftLinear  = b <= 0 ? 1.0 : max(0.0, 1.0 - b)
        let rightLinear = b >= 0 ? 1.0 : max(0.0, 1.0 + b)
        return (leftLinear, rightLinear)
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

    private static func apply(bands profileBands: [EQBand], to eq: AVAudioUnitEQ?) {
        guard let eq else { return }
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

    /// 1 kHz reference tone for the dB-SPL calibration workflow. Routed
    /// straight into `mainMixerNode` so it bypasses the user's EQ chain
    /// (the calibration tone must not be coloured by the user's curve).
    /// Amplitude is fixed at −12 dBFS — loud enough to register cleanly on
    /// a phone SPL meter, with enough headroom to clear the limiter
    /// without triggering compression.
    static let calibrationToneDBFS: Float = -12
    private var calibrationTonePlayer: AVAudioPlayerNode?
    private var calibrationToneBuffer: AVAudioPCMBuffer?
    @Published private(set) var calibrationToneEnabled: Bool = false

    func setCalibrationTone(_ on: Bool) {
        if on {
            guard calibrationTonePlayer == nil else { return }
            let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
            let sr = mixerFormat.sampleRate > 0 ? mixerFormat.sampleRate : 48000
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else { return }
            // One second of audio looped — long enough that the loop seam
            // is between cycle boundaries (1 kHz divides cleanly into any
            // common sample rate) so there's no audible click on wrap.
            let frames: AVAudioFrameCount = AVAudioFrameCount(sr)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames

            let freq: Float = 1000
            let twoPi: Float = 2 * .pi
            let sampleRate = Float(sr)
            let amplitude = pow(10.0, Self.calibrationToneDBFS / 20.0)  // −12 dBFS → ≈0.251
            for ch in 0..<Int(format.channelCount) {
                guard let p = buffer.floatChannelData?[ch] else { continue }
                for i in 0..<Int(frames) {
                    p[i] = sin(twoPi * freq * Float(i) / sampleRate) * amplitude
                }
            }

            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            calibrationTonePlayer = player
            calibrationToneBuffer = buffer
            calibrationToneEnabled = true
            log.info("Calibration tone: 1 kHz @ \(Self.calibrationToneDBFS) dBFS, \(Int(sr)) Hz output")
        } else {
            if let player = calibrationTonePlayer {
                player.stop()
                engine.detach(player)
            }
            calibrationTonePlayer = nil
            calibrationToneBuffer = nil
            calibrationToneEnabled = false
            log.info("Calibration tone stopped")
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
