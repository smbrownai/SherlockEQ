import Foundation
import AVFoundation
import AudioToolbox
import Combine
import OSLog

/// AVAudioEngine graph that takes the L/R source nodes from `CATapEngine`,
/// runs each through an independent per-ear `BiquadCascade`, and sums to stereo
/// output via `mainMixerNode`.
@MainActor
final class SherlockEQAudioEngine: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var referenceMode = false
    @Published private(set) var testCurveEnabled = false
    /// Non-nil when tap rate differs from output rate — audio quality is
    /// degraded by AVAudioMixerNode's internal resampler on this path.
    /// Cleared when rates match.

    private let engine = AVAudioEngine()
    private let log = Logger(subsystem: "com.shawnbrown.SherlockEQ", category: "AudioEngine")

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
    /// Per-ear dynamic (level-dependent) EQ stage, owned by CATapEngine
    /// alongside the cascades. Stored weak at attach time so `applyProfile`
    /// can push per-feature config and Reference Mode can bypass it.
    private weak var leftDynamics: DynamicBandProcessor?
    private weak var rightDynamics: DynamicBandProcessor?
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
    @Published private(set) var toneEnabled: Bool = false
    @Published private(set) var outputFormatDescription: String = "—"

    private var sumMixer: AVAudioMixerNode?
    private var limiter: AVAudioUnitEffect?
    /// 1-band-bypassed AVAudioUnitEQ used purely as a gain stage. Its
    /// `globalGain` (-96…+24 dB range) gives reliable dB control where
    /// `mainMixerNode.outputVolume` silently no-ops on this graph.
    private var masterGainStage: AVAudioUnitEQ?
    private var masterGainDB: Double = 0

    /// Called when AVAudioEngine itself decides to reconfigure (route
    /// change, Bluetooth disconnect/reconnect, sample-rate negotiation).
    /// AVAudioEngine stops rendering when this notification fires and
    /// the graph must be rebuilt. The host (AudioState) wires this to
    /// its `rebuildAudioGraph()` path so a Bluetooth handoff or other
    /// route change doesn't strand the user in silence.
    var onConfigurationChange: (() -> Void)?

    /// Lazy-installed observer for `.AVAudioEngineConfigurationChange`.
    /// Held so we can remove it on deinit / detach if needed.
    private var configChangeObserver: NSObjectProtocol?

    init() {
        installConfigurationChangeObserver()
    }

    deinit {
        if let token = configChangeObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func installConfigurationChangeObserver() {
        // The notification can fire on a non-main thread; hop to main
        // before invoking the callback so the rebuild runs through
        // AudioState's @MainActor methods.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.log.info("AVAudioEngine configuration change — rebuilding graph")
                self.onConfigurationChange?()
            }
        }
    }

    /// Outcome of `attach(...)`. `.sampleRateMismatch` is distinguished from
    /// `.failed` because it's the one case a caller may want to retry: it
    /// can reflect a momentarily-stale `sourceFormat` snapshot on the tap
    /// (see `attach`'s doc comment) rather than a real, persistent problem.
    enum AttachOutcome {
        case success
        case sampleRateMismatch(sourceHz: Int, outputHz: Int)
        case failed
    }

    /// Wires up the graph with the L/R source nodes from the tap.
    /// Tears down any prior graph first; safe to call on device change.
    ///
    /// Returns `.success` on success. On failure `lastError` is set with the
    /// specific reason and the caller MUST NOT call `start()` — doing so
    /// would mask the real error with a generic "no sources" message.
    /// `.sampleRateMismatch` does NOT set `lastError` — see below.
    ///
    /// Sample-rate handling: the `sampleRate` passed in is the output
    /// device's nominal rate (which is also the rate the aggregate's
    /// drift-compensated IOProc delivers). The engine's outputNode rate
    /// matches, so the graph is uniform end-to-end and no bridge / SRC
    /// node is required. See memory `audio-engine-sr-mismatch`.
    ///
    /// In practice the two rates can briefly disagree right after a sleep/
    /// wake or output-route change: `sampleRate` here comes from
    /// `CATapEngine.sourceFormat`, a snapshot cached the last time the tap
    /// finished its own (async) rebuild, while `outRate` below is read live
    /// from the engine. Two independent triggers can both schedule a graph
    /// rebuild (the tap's own device-change handling, and AVAudioEngine's
    /// own configuration-change notification) and the second can win the
    /// race before the tap has refreshed its cached format. Rather than
    /// treat every mismatch as a hard failure, this returns
    /// `.sampleRateMismatch` without setting `lastError`, so the caller can
    /// retry — see `AudioState.rebuildAudioGraph()`.
    @discardableResult
    func attach(
        leftSource: AVAudioSourceNode,
        rightSource: AVAudioSourceNode,
        leftEQCascade: BiquadCascade,
        rightEQCascade: BiquadCascade,
        leftDynamics: DynamicBandProcessor,
        rightDynamics: DynamicBandProcessor,
        sampleRate: Double
    ) -> AttachOutcome {
        teardownGraph()
        // A fresh graph build is a clean slate for the start() backoff
        // budget. Without this, a wake that burned all retries overnight
        // would leave startRetryCount maxed out, so the next rebuild's
        // start() gets a single attempt with no backoff. Reset here (the
        // new-graph boundary) — NOT at the top of start(), which the retry
        // loop re-enters and would reset the counter into an infinite loop.
        startRetryCount = 0

        guard let tapFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        ) else {
            lastError = "Could not build stereo format @ \(sampleRate) Hz"
            return .failed
        }

        // Checked before attaching anything: a mismatch here means we bail
        // out entirely without touching the engine's node graph, so a
        // retried `attach()` call never has to clean up a partially wired
        // graph from an earlier failed attempt.
        let outRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if outRate > 0 && Int(outRate.rounded()) != Int(sampleRate.rounded()) {
            log.error("SR mismatch: source \(Int(sampleRate)) Hz vs output \(Int(outRate)) Hz — deferring to caller's retry")
            return .sampleRateMismatch(sourceHz: Int(sampleRate.rounded()), outputHz: Int(outRate.rounded()))
        }

        self.tapSampleRate = sampleRate
        self.leftEQCascade = leftEQCascade
        self.rightEQCascade = rightEQCascade
        self.leftDynamics = leftDynamics
        self.rightDynamics = rightDynamics
        leftDynamics.setSampleRate(sampleRate)
        rightDynamics.setSampleRate(sampleRate)

        engine.attach(leftSource)
        engine.attach(rightSource)

        // Sine tone generator — direct path to mainMixer, no EQ.
        if let toneNode = toneGenerator.makeSourceNode(sampleRate: sampleRate) {
            engine.attach(toneNode)
            engine.connect(toneNode, to: engine.mainMixerNode, format: tapFormat)
            toneSourceNode = toneNode
        }

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

        let sum = AVAudioMixerNode()
        engine.attach(sum)
        engine.connect(leftSource, to: lBal, format: tapFormat)
        engine.connect(rightSource, to: rBal, format: tapFormat)
        engine.connect(lBal, to: sum, format: tapFormat)
        engine.connect(rBal, to: sum, format: tapFormat)
        engine.connect(sum, to: lim, format: tapFormat)
        engine.connect(lim, to: gainStage, format: tapFormat)
        engine.connect(gainStage, to: mixer, format: tapFormat)
        self.sumMixer = sum
        log.info("Graph attached @ \(Int(sampleRate)) Hz end-to-end")

        self.leftSource = leftSource
        self.rightSource = rightSource

        // EQ cascades + dynamic stage bypass when the user wants to hear
        // raw signal.
        leftEQCascade.setBypassed(referenceMode)
        rightEQCascade.setBypassed(referenceMode)
        leftDynamics.setBypassed(referenceMode)
        rightDynamics.setBypassed(referenceMode)
        return .success
    }

    /// Called by the caller once it gives up retrying a persistent
    /// `.sampleRateMismatch` — surfaces the same banner `attach()` used to
    /// set directly, now that we know it isn't just a transient snapshot lag.
    func reportPersistentSampleRateMismatch(sourceHz: Int, outputHz: Int) {
        lastError = "Unexpected SR mismatch: source \(sourceHz) Hz vs output \(outputHz) Hz"
    }

    func start() {
        guard !isRunning else { return }
        do {
            engine.prepare()
            try engine.start()
            isRunning = true
            lastError = nil
            startRetryCount = 0
            let f = engine.outputNode.inputFormat(forBus: 0)
            outputFormatDescription = "\(Int(f.sampleRate)) Hz · \(f.channelCount) ch · \(Self.formatLabel(f.commonFormat))"
            log.info("AVAudioEngine started — output expects \(self.outputFormatDescription)")
        } catch {
            isRunning = false
            let ns = error as NSError
            log.error(
                "AVAudioEngine.start failed: domain=\(ns.domain, privacy: .public) code=\(ns.code) userInfo=\(ns.userInfo, privacy: .public) — \(error.localizedDescription, privacy: .public)"
            )
            if Self.isTransientHALFailure(ns), startRetryCount < Self.maxStartRetries {
                // The HAL refused to open the output device right now —
                // a route change, sample-rate renegotiation, or (most
                // often after the Mac has slept overnight) the device
                // hasn't been re-published yet. These clear on their own
                // once the HAL settles, so retry with escalating backoff
                // and hold the banner until the retries are exhausted.
                startRetryCount += 1
                let delayMS = 200 << (startRetryCount - 1)   // 200, 400, 800 ms
                log.info("Transient HAL failure (code \(ns.code)) — start() retry \(self.startRetryCount)/\(Self.maxStartRetries) in \(delayMS) ms")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delayMS) * 1_000_000)
                    guard let self else { return }
                    guard !self.isRunning else { return }
                    self.start()
                }
                return
            }
            lastError = "AVAudioEngine.start: \(error.localizedDescription)"
        }
    }

    /// True if `error` is a HAL-layer transient failure — the output
    /// device refused to open right now but should accept a fresh
    /// `start()` once the underlying transition settles. Caller retries
    /// with escalating backoff. Qualifying codes live in the avfaudio or
    /// POSIX domains:
    ///
    /// - `EAGAIN` (35) — route / sample-rate renegotiation still in flight.
    /// - `'nope'` (1852797029) — the avfaudio "cannot start IO in the
    ///   current context" code, most often seen when the Mac wakes from
    ///   an overnight sleep before the HAL has re-published the device.
    /// - the HAL device/object transient statuses (`'!dev'`, `'!obj'`,
    ///   `'stop'`, `'what'`) — avfaudio surfaces the underlying HAL
    ///   `OSStatus` as the NSError code when the output device handle is
    ///   stale or not-yet-ready after wake. Kept in sync with
    ///   `CATapEngine.transientHALStatuses`.
    private static func isTransientHALFailure(_ error: NSError) -> Bool {
        guard error.domain == "com.apple.coreaudio.avfaudio"
            || error.domain == NSPOSIXErrorDomain
        else { return false }
        return error.code == 35 || transientHALStatuses.contains(OSStatus(error.code))
    }

    /// Transient HAL start statuses avfaudio may re-surface as its NSError
    /// code after a wake/route change. Mirrors
    /// `CATapEngine.transientHALStatuses`.
    ///
    /// - `'nope'` (1852797029) — cannot act in the current context.
    /// - `'!dev'` (560227702)  — device handle gone stale.
    /// - `'!obj'` (560947818)  — stale object ID.
    /// - `'stop'`              — HAL/device not yet running.
    /// - `'what'`              — generic post-wake hiccup.
    private static let transientHALStatuses: Set<OSStatus> = [
        OSStatus(kAudioHardwareIllegalOperationError),
        OSStatus(kAudioHardwareBadDeviceError),
        OSStatus(kAudioHardwareBadObjectError),
        OSStatus(kAudioHardwareNotRunningError),
        OSStatus(kAudioHardwareUnspecifiedError),
    ]

    /// Counts consecutive transient-failure retries so the chain can't
    /// loop forever — once it reaches `maxStartRetries` the banner
    /// surfaces. Reset to 0 on a successful start.
    private var startRetryCount = 0
    private static let maxStartRetries = 3

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
        log.debug("Spectrum tap installed (\(Int(format.sampleRate)) Hz, buffer \(bufferSize))")
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
        if let s = sumMixer { engine.detach(s); sumMixer = nil }
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
        // Dynamic stage is owned by CATapEngine too — clear to all-disabled
        // and bypass so no stale feature config survives the teardown, then
        // drop our refs.
        leftDynamics?.configure(slots: [])
        rightDynamics?.configure(slots: [])
        leftDynamics?.setBypassed(true)
        rightDynamics?.setBypassed(true)
        leftDynamics = nil
        rightDynamics = nil
        if let t = toneSourceNode { engine.detach(t); toneSourceNode = nil }
        // The diagnostic test tone and the SPL-calibration tone are
        // AVAudioPlayerNodes attached straight to mainMixerNode, outside the
        // graph wiring above. They must be detached here too — otherwise each
        // rebuild (device change, sleep/wake) leaks an orphaned node, leaves
        // the @Published toggle stuck "on" with no audible tone, and the
        // `guard …Player == nil` re-arm guard then permanently no-ops. This
        // also silently corrupted an in-progress dBA calibration on any route
        // change. Reset the pointers + flags so the tone can be re-armed.
        if let tp = tonePlayer { tp.stop(); engine.detach(tp); tonePlayer = nil }
        if toneEnabled { toneEnabled = false }
        if let cp = calibrationTonePlayer { cp.stop(); engine.detach(cp); calibrationTonePlayer = nil }
        if calibrationToneEnabled { calibrationToneEnabled = false }
    }

    // MARK: - Controls

    func setReferenceMode(_ on: Bool) {
        referenceMode = on
        // EQ cascades carry AutoEQ + profile bands + notch + trim —
        // a single bypass toggle takes the whole stack out of the path
        // so the user hears the truly-unprocessed source signal.
        leftEQCascade?.setBypassed(on)
        rightEQCascade?.setBypassed(on)
        // Reference Mode means truly unprocessed — the dynamic stage goes
        // out of the path alongside the cascade.
        leftDynamics?.setBypassed(on)
        rightDynamics?.setBypassed(on)
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

    /// Flatten both per-ear cascades to identity. Used when the active
    /// profile is deleted or otherwise disappears — without this, the
    /// previously-applied profile's bands would stay live and the user
    /// would still be hearing the deleted profile's EQ even though the
    /// UI shows "no profile selected".
    func flattenChain() {
        leftBalanceMixer?.outputVolume = 1
        rightBalanceMixer?.outputVolume = 1
        leftEQCascade?.setBands([], preampDB: 0, sampleRate: tapSampleRate)
        rightEQCascade?.setBands([], preampDB: 0, sampleRate: tapSampleRate)
        // Dynamic features clear too — a flattened chain is fully unprocessed.
        leftDynamics?.configure(slots: [])
        rightDynamics?.configure(slots: [])
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

        // Combined per-ear EQ stack (cascaded in series → summed in dB):
        //   1. AutoEQ headphone-correction bands (same for both ears —
        //      AutoEQ files describe a stereo pair, not per-cup)
        //   2. Audiogram hearing-correction bands for this ear
        //   3. Profile (user/preset) bands for this ear
        //   4. Tinnitus notch (shared across ears, spec §5.3)
        //
        // The audiogram correction sits ahead of the user/preset EQ so the
        // two layer rather than collide: presets edit `ear.bands` only, and
        // the prescribed hearing correction in `ear.correctionBands` is
        // always applied on top of whatever tone shape the user picks.
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
        // Correction at its EFFECTIVE strength (target compensationFactor ×
        // acclimatization ramp) — the same helper the previews draw from,
        // so heard always equals drawn (phase3 §5).
        let correction = profile.effectiveCorrectionBands()
        let combinedLeftBands = autoBands + correction.left + profile.leftEar.bands + leftNotchBand
        let combinedRightBands = autoBands + correction.right + profile.rightEar.bands + rightNotchBand
        let combinedPreampDB = (profile.autoEQPreampDB ?? 0) + profile.globalTrimDB

        leftEQCascade?.setBands(combinedLeftBands, preampDB: combinedPreampDB, sampleRate: tapSampleRate)
        rightEQCascade?.setBands(combinedRightBands, preampDB: combinedPreampDB, sampleRate: tapSampleRate)
        leftEQCascade?.setBypassed(referenceMode)
        rightEQCascade?.setBypassed(referenceMode)

        // Dynamic (level-dependent) features — folded per-ear from
        // `profile.dynamics`. The strength/sensitivity sliders are mapped
        // to sign-carrying max delta + threshold offset here so the audio
        // thread does no slider arithmetic.
        leftDynamics?.configure(slots: Self.dynamicSlots(profile.dynamics, ear: .left))
        rightDynamics?.configure(slots: Self.dynamicSlots(profile.dynamics, ear: .right))
        leftDynamics?.setBypassed(referenceMode)
        rightDynamics?.setBypassed(referenceMode)

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
        // Profile name, notch description, and the dynamics summary are all
        // either user-authored or derived from the hearing profile — mark
        // .private so they're redacted from sysdiagnose/support-shared logs
        // and any `log show` capture, while staying inspectable locally via
        // Console.app with private data enabled. autoEQ is just a headphone
        // model name (not health data) and stays .public.
        log.debug("Applied profile \(profile.name, privacy: .private) — L:\(combinedLeftBands.count) bands, R:\(combinedRightBands.count) bands, preamp+trim:\(combinedPreampDB) dB, balance:\(profile.balance, format: .fixed(precision: 2)), notch:\(notchDescription, privacy: .private), autoEQ:\(profile.autoEQName ?? "none", privacy: .public), dynamics:\(Self.dynamicsSummary(profile.dynamics), privacy: .private)")
    }

    /// Map a profile's dynamic settings for one ear into the processor's
    /// slot config. All three kinds are passed every time (disabled slots
    /// are no-ops in the processor); strength/sensitivity are pre-mapped to
    /// the DSP domain here.
    private static func dynamicSlots(_ dynamics: DynamicProcessingSettings, ear: EQBandLookup.Ear) -> [DynamicBandProcessor.SlotConfig] {
        DynamicFeatureKind.allCases.map { kind in
            let s = dynamics.settings(for: kind, ear: ear)
            return DynamicBandProcessor.SlotConfig(
                kind: kind,
                enabled: s.enabled,
                maxDeltaDB: kind.maxDeltaDB(strength: s.strength),
                thresholdOffsetDB: kind.thresholdOffsetDB(sensitivity: s.sensitivity)
            )
        }
    }

    /// Compact one-line summary of enabled dynamic features for the
    /// applyProfile debug log, e.g. `sib L+R 0.7, harsh off, speech L 0.4`.
    private static func dynamicsSummary(_ d: DynamicProcessingSettings) -> String {
        func tag(_ kind: DynamicFeatureKind, _ short: String) -> String {
            let l = d.settings(for: kind, ear: .left)
            let r = d.settings(for: kind, ear: .right)
            switch (l.enabled, r.enabled) {
            case (false, false): return "\(short) off"
            case (true, true):
                return l.strength == r.strength
                    ? "\(short) L+R \(String(format: "%.1f", l.strength))"
                    : "\(short) L \(String(format: "%.1f", l.strength)) R \(String(format: "%.1f", r.strength))"
            case (true, false): return "\(short) L \(String(format: "%.1f", l.strength))"
            case (false, true): return "\(short) R \(String(format: "%.1f", r.strength))"
            }
        }
        return [tag(.sibilanceTamer, "sib"), tag(.harshnessControl, "harsh"), tag(.speechPresence, "speech")]
            .joined(separator: ", ")
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
        // Single source of truth on the model: a finite-depth parametric cut
        // (not a pure RBJ notch, whose gain-independent null made the Depth
        // control inert and whose 1/Q width inverted Narrow/Wide). See
        // `TinnitusNotch.asEQBand()`.
        notch.asEQBand().map { [$0] } ?? []
    }

    /// 1 kHz reference tone for the dB-SPL calibration workflow. Routed
    /// straight into `mainMixerNode` so it bypasses the user's EQ chain
    /// (the calibration tone must not be coloured by the user's curve).
    /// Amplitude is fixed at −12 dBFS — loud enough to register cleanly on
    /// a phone SPL meter, with enough headroom to clear the limiter
    /// without triggering compression.
    static let calibrationToneDBFS: Float = -12
    private var calibrationTonePlayer: AVAudioPlayerNode?
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
            calibrationToneEnabled = true
            log.info("Calibration tone: 1 kHz @ \(Self.calibrationToneDBFS) dBFS, \(Int(sr)) Hz output")
        } else {
            if let player = calibrationTonePlayer {
                player.stop()
                engine.detach(player)
            }
            calibrationTonePlayer = nil
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
            toneEnabled = true
            log.info("Test tone enabled @ \(Int(sr)) Hz")
        } else {
            if let player = tonePlayer {
                player.stop()
                engine.detach(player)
            }
            tonePlayer = nil
            toneEnabled = false
            log.info("Test tone disabled")
        }
    }

}
