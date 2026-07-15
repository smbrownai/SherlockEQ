import Foundation
import AVFoundation
import Combine
import CoreAudio
import OSLog

@MainActor
final class CATapEngine: ObservableObject {

    enum State: Equatable {
        case idle
        case awaitingPermission
        case permissionDenied
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var permissionGranted: Bool = false
    /// Raw CoreAudio handle for the device the tap is bound to. Kept for
    /// internal use (change-detection on the default-output listener,
    /// the `onOutputDeviceChanged` callback signature, OSLog statements);
    /// the UI should prefer `currentOutputDeviceDescription` so the
    /// CoreAudio type doesn't leak into the view layer.
    @Published private(set) var currentOutputDeviceID: AudioDeviceID = kAudioObjectUnknown
    @Published private(set) var currentOutputDeviceName: String = "—"
    /// UID of the current default output device — the stable identity used
    /// for profile auto-switching and the AutoEQ device-mismatch check
    /// (phase3-make-correction-land.md §7). Resolved in the off-main prep
    /// step alongside the name; nil until the first tap start.
    @Published private(set) var currentOutputDeviceUID: String?
    /// True when the current output device's transport is the built-in
    /// speakers — the case where a headphone correction is always wrong,
    /// not just probably (drives the mismatch warning's stronger copy).
    @Published private(set) var currentOutputDeviceIsBuiltIn: Bool = false

    /// Pre-formatted "Name (#id)" string for diagnostic UI. DebugView
    /// reads this instead of touching `currentOutputDeviceID` directly,
    /// so the CoreAudio `AudioDeviceID` type stays out of the view layer.
    var currentOutputDeviceDescription: String {
        "\(currentOutputDeviceName) (#\(currentOutputDeviceID))"
    }

    /// Mono source node for the left channel of the captured stream.
    /// Emits **stereo** with L = tapped L, R = 0 — so a downstream EQ can process
    /// it independently and the result re-mixes cleanly with the right chain.
    private(set) var leftSourceNode: AVAudioSourceNode?
    /// Mono source node for the right channel (stereo with L = 0, R = tapped R).
    private(set) var rightSourceNode: AVAudioSourceNode?

    /// Per-ear EQ biquad cascades, applied in the source-node render
    /// block immediately after the ring read. Carry the full per-ear
    /// EQ stack: AutoEQ headphone correction + profile bands + tinnitus
    /// notch + global trim. Replaces an upstream `AVAudioUnitEQ` chain
    /// that introduced cross-channel content under extreme balance
    /// pans — processing the filter on a single mono Float buffer per
    /// render block keeps the L and R signal paths physically
    /// separate. SherlockEQAudioEngine reconfigures these via
    /// `setBands(...)` on every profile change.
    let leftEQCascade = BiquadCascade()
    let rightEQCascade = BiquadCascade()

    /// Stage-A cascades: the AutoEQ headphone correction (+ its preamp),
    /// split out ahead of the adaptive stage so its detectors see a
    /// headphone-flattened signal — prescribed gains mean the same thing
    /// on every transducer (phase4-adaptive-correction.md §4.1). In
    /// Steady mode this split is mathematically inert (an IIR cascade
    /// commutes); it exists so Adaptive can sit between the two halves.
    let leftAutoEQCascade = BiquadCascade()
    let rightAutoEQCascade = BiquadCascade()

    /// Per-ear Adaptive Correction (level-following WDRC). Enabled only
    /// for profiles in `.adaptive` correction mode; bit-exact passthrough
    /// otherwise. Owned here like the cascades — the render block captures
    /// strongly, no isolation hop.
    let leftAdaptive = AdaptiveCorrectionProcessor()
    let rightAdaptive = AdaptiveCorrectionProcessor()

    /// Per-ear level-dependent ("dynamic") EQ stage, sitting in the
    /// render block immediately after the static cascade and before the
    /// peak counters / pre-spectrum side-channel. Owned here for the same
    /// reason as the cascades — the source-node render block captures them
    /// strongly without an isolation hop. SherlockEQAudioEngine pushes the
    /// per-feature config via `configure(...)` on every profile change.
    let leftDynamics = DynamicBandProcessor()
    let rightDynamics = DynamicBandProcessor()

    /// Format both source nodes emit (stereo, tap sample rate).
    private(set) var sourceFormat: AVAudioFormat?
    /// Tap stream descriptor — sample rate, channel count of the raw tap.
    private(set) var tapFormat: AVAudioFormat?

    var onOutputDeviceChanged: ((AudioDeviceID) -> Void)?

    /// Side-channel for the pre-EQ spectrum analyzer. The render block
    /// captures this strongly and reads the callback through it each
    /// frame — but the field needs synchronisation: a closure is two
    /// words (function pointer + context) and a write from the main
    /// thread during a render-block read could tear and crash the
    /// IOProc. The slot wraps its state in `OSAllocatedUnfairLock`
    /// (same pattern as `AudioCounter` / `BiquadCascade`).
    let preIngest = PreSpectrumIngestSlot()

    /// Cross-thread holder for the pre-EQ ingest callback plus its
    /// diagnostic counters. Writers (main thread) call `setCallback`;
    /// the audio render block calls `snapshotCallbackForRender` to
    /// atomically read the callback and bump the entry counter, then
    /// invokes the closure OUTSIDE the lock so a contended write from
    /// main never stalls the IOProc for the duration of the ingest.
    ///
    /// `nonisolated` because the outer `CATapEngine` is `@MainActor` —
    /// without this, the nested class would inherit that isolation and
    /// the audio render block couldn't legally touch it.
    nonisolated final class PreSpectrumIngestSlot: @unchecked Sendable {
        typealias Callback = (UnsafePointer<Float>, Int, Double) -> Void

        private struct State {
            var callback: Callback?
            var renderBlockEntries: Int = 0
            var callbackInvocations: Int = 0
        }
        private let stateLock = OSAllocatedUnfairLock<State>(initialState: State())

        /// Assign a new callback (or `nil` to detach). Main-thread API.
        func setCallback(_ callback: Callback?) {
            stateLock.withLock { $0.callback = callback }
        }

        /// Bump the render-block entry counter and return the current
        /// callback. Called once per render block from the audio thread.
        func snapshotCallbackForRender() -> Callback? {
            stateLock.withLock { state in
                state.renderBlockEntries &+= 1
                return state.callback
            }
        }

        /// Record that a callback invocation completed. Called after
        /// the snapshot callback runs (outside the lock).
        func recordCallbackInvocation() {
            stateLock.withLock { $0.callbackInvocations &+= 1 }
        }

        /// Diagnostic reads — DebugView samples at ~10 Hz.
        var renderBlockEntries: Int { stateLock.withLock { $0.renderBlockEntries } }
        var callbackInvocations: Int { stateLock.withLock { $0.callbackInvocations } }
    }

    /// Builds a mono `(L+R)/2` pre-EQ buffer for the input-ghost analyzer out
    /// of the two independent source-node render blocks. The right block stashes
    /// its raw channel; the left block averages it with its own and hands the
    /// result to the pre-EQ side-channel. `(L+R)/2` matches the mono mixing
    /// `SpectrumAnalyzer.ingest(_:)` applies to the post-EQ output, so the input
    /// ghost and output overlay share one level basis.
    ///
    /// No locking: both source nodes are pulled sequentially on the single
    /// AVAudioEngine render thread, so the scratch is only ever touched from one
    /// thread. The left block reads whatever the right block last stashed —
    /// at most one render slice stale if the graph happens to pull left first,
    /// which is imperceptible for a time-averaged spectrum. `right` is fully
    /// initialised, so a left slice longer than the stash (or the very first
    /// slice, before right has run) just averages against silence.
    ///
    /// `nonisolated` for the same reason as `PreSpectrumIngestSlot`: the outer
    /// engine is `@MainActor` and the render block must touch this legally.
    nonisolated final class StereoPreMix: @unchecked Sendable {
        private let capacity: Int
        private let right: UnsafeMutablePointer<Float>
        private let summed: UnsafeMutablePointer<Float>

        init(capacity: Int) {
            self.capacity = capacity
            right = .allocate(capacity: capacity)
            right.initialize(repeating: 0, count: capacity)
            summed = .allocate(capacity: capacity)
            summed.initialize(repeating: 0, count: capacity)
        }
        deinit {
            right.deinitialize(count: capacity); right.deallocate()
            summed.deinitialize(count: capacity); summed.deallocate()
        }

        /// Right render block: stash this slice's raw right-channel pre-EQ
        /// samples (called before the EQ cascade mutates them in place).
        func stashRight(_ ptr: UnsafePointer<Float>, count: Int) {
            right.update(from: ptr, count: min(count, capacity))
        }

        /// Left render block: average left with the stashed right and return
        /// the mono pointer + frame count for the pre-EQ analyzer.
        func mixedMono(left: UnsafePointer<Float>, count: Int) -> (UnsafePointer<Float>, Int) {
            let n = min(count, capacity)
            for i in 0..<n { summed[i] = (left[i] + right[i]) * 0.5 }
            return (UnsafePointer(summed), n)
        }
    }

    /// Diagnostic counters. Sampled from the UI; updated from realtime threads.
    let tapFramesIn = AudioCounter()
    let leftSourceFramesOut = AudioCounter()
    let rightSourceFramesOut = AudioCounter()
    /// Most recent peak (max abs sample) seen by the IOProc — milli-unit scale
    /// (samples are in -1…+1 float range; we store as Int milli-units 0…1000).
    let ringInputPeakMilli = AudioCounter()
    /// Most recent peak written out from the source nodes (post-ring read).
    let sourceOutputPeakMilli = AudioCounter()
    /// ABL layout the IOProc sees (snapshotted each call so it stays current).
    let ioProcBufferCount = AudioCounter()
    let ioProcFirstChannels = AudioCounter()
    let ioProcFirstByteSize = AudioCounter()
    /// Number of IOProc invocations — paired with `tapFramesIn` so the
    /// Debug view can show mean frames/call (sanity check on the aggregate's
    /// drift compensation; see memory `audio-engine-sr-mismatch`).
    let ioProcCalls = AudioCounter()
    /// Process object ID we excluded from the global tap (our own).
    let excludedProcessObjectID = AudioCounter()

    private let log = Logger(subsystem: "com.shawnbrown.SherlockEQ", category: "CATapEngine")

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    private var leftRing: TapRingBuffer?
    private var rightRing: TapRingBuffer?

    /// Number of channels the process tap itself contributes to the
    /// aggregate's input scope, read from the tap object's own format at
    /// prep time (not inferred). The IOProc uses this to locate the tap's
    /// channels as the trailing `tapChannelCount` slice — robust to a mono
    /// tap or an output device that also exposes hardware inputs ahead of
    /// the tap. Defaults to 2 (we create a stereo global tap); only ever
    /// less if the tap format query surfaces a mono tap.
    private var tapChannelCount: Int = 2

    /// Installed CoreAudio property listeners, kept by block reference
    /// so `AudioObjectRemovePropertyListenerBlock` can match the
    /// original closures when tearing down (the API matches by block
    /// identity — a fresh empty block won't match and leaks the
    /// listener). The system-object default-output listener stays for
    /// the life of the engine; the per-device config listeners get
    /// reinstalled whenever the device binding changes.
    private struct InstalledListener {
        var target: AudioObjectID
        var selector: AudioObjectPropertySelector
        var block: AudioObjectPropertyListenerBlock
    }
    private var installedListeners: [InstalledListener] = []

    deinit {
        Self.tearDownSync(
            tapID: tapID,
            aggregateDeviceID: aggregateDeviceID,
            ioProcID: ioProcID
        )
    }

    // MARK: - Public lifecycle

    /// Re-check System Audio Recording permission. macOS lets the user
    /// revoke it in System Settings mid-session; when that happens the
    /// IOProc silently delivers zeros and nothing in our state changes.
    /// Call this when the app becomes active (the natural moment the
    /// user has returned from toggling something in Settings) — if the
    /// permission has dropped while we thought we were running, flip
    /// to `.failed` and tear down so the user sees the same actionable
    /// error message as the first-time-denied path.
    func recheckAudioCapturePermission() {
        // Only meaningful while we believed we were tapping. In other
        // states this is either irrelevant (.idle, .awaitingPermission,
        // .permissionDenied) or already handled (.failed, .starting).
        guard case .running = state else { return }
        guard AudioCapturePermission.preflight() != .authorized else { return }
        log.error("System Audio Recording permission revoked mid-session — tearing tap down")
        // Route the teardown through the same FIFO serializer as start/stop/
        // device-change. Calling `tearDownTapAndAggregate()` directly here let
        // it interleave with an in-flight rebuild (a queued `performStart`),
        // which leaks the tap/aggregate CoreAudio handles — exactly what the
        // serializer exists to prevent. Re-confirm state + permission inside
        // the queue, since a rebuild ahead of us may have changed both.
        Task { @MainActor in
            await enqueue { [weak self] in
                guard let self else { return }
                guard case .running = self.state,
                      AudioCapturePermission.preflight() != .authorized else { return }
                self.state = .failed("""
                    System Audio Recording permission was revoked. \
                    Open System Settings → Privacy & Security → System Audio \
                    Recording, re-enable SherlockEQ, then quit and relaunch the app.
                    """)
                self.tearDownTapAndAggregate()
            }
        }
    }

    func requestPermissionAndStart() async {
        state = .awaitingPermission

        // System Audio Recording (TCC service `kTCCServiceAudioCapture`) is
        // the real gating permission for CATap. The bucket name in System
        // Settings differs by OS — on macOS 15+ it appears as the standalone
        // "System Audio Recording" entry alongside Audio Hijack / ARK; on
        // 14.x it's grouped under Screen Recording in the UI, but the same
        // TCC service is checked. Without it the IOProc silently delivers
        // zeros — see memory `catap-screen-recording-permission`.
        //
        // We use Apple's private TCC SPI (modeled on insidegui/AudioCap)
        // because there is no public preflight/request API for the audio-
        // capture bucket. The previous `CGRequestScreenCaptureAccess`
        // approach worked, but routed the app into the broader
        // "Screen & System Audio Recording" bucket — wrong place for an
        // audio-only tool.
        //
        // We deliberately do NOT request microphone TCC: CATap reads other
        // processes' audio via the CoreAudio process-tap API, not via an
        // input device, so the mic prompt was misleading ("microphone" when
        // we never touch the mic).
        if AudioCapturePermission.preflight() != .authorized {
            log.info("System audio capture access not granted — requesting...")
            let granted = await AudioCapturePermission.request()
            if !granted {
                permissionGranted = false
                state = .failed("""
                    System Audio Recording permission is required. \
                    Open System Settings → Privacy & Security → System Audio \
                    Recording, enable SherlockEQ, then quit and relaunch the app.
                    """)
                return
            }
        }
        permissionGranted = true

        await start()
    }

    /// Strict-FIFO serializer for `start` / `stop` / device-topology
    /// rebuilds. Every triggering path (UI startAll, default-output
    /// listener, stream-config listener, sample-rate listener, wake
    /// handler) awaits the previous in-flight Task before running its
    /// own body. Without this, two rapid device-change notifications
    /// would each run `tearDownTapAndAggregate()` followed by
    /// `performStart()` interleaved against the other, leaking the
    /// first invocation's CoreAudio handles when its `applyTapPrep`
    /// overwrites them.
    private var inFlight: Task<Void, Never>?

    private func enqueue(_ work: @escaping @MainActor @Sendable () async -> Void) async {
        // Chain each new work item after the previous one so they run
        // in strict FIFO. A completed Task is harmless to leave pinned
        // — its memory is trivial and the next enqueue replaces it —
        // so we don't bother trying to clear `inFlight` back to nil
        // after our work finishes (Task is a value type, no `===` to
        // match against the slot atomically).
        let previous = inFlight
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        inFlight = task
        await task.value
    }

    func start() async {
        await enqueue { [weak self] in
            guard let self else { return }
            // Re-entrancy guard: if we became `.running` while waiting
            // in the queue (e.g. another caller's start() landed
            // first), don't redo the work.
            if case .running = self.state { return }
            await self.performStart()
        }
    }

    func stop() async {
        await enqueue { [weak self] in
            guard let self else { return }
            self.tearDown()
            self.state = .idle
        }
    }

    private func performStart() async {
        state = .starting
        var attempt = 0
        while true {
            do {
                let prep = try await Task.detached(priority: .userInitiated) {
                    try Self.prepareTapAndAggregate()
                }.value
                try applyTapPrep(prep)
                try startIO()
                installDefaultOutputDeviceListener()
                state = .running
                log.info("CATapEngine running on device \(self.currentOutputDeviceID)")
                return
            } catch {
                // Free whatever the failed attempt created before retrying
                // or surfacing — leftover handles would leak across rebuilds.
                tearDown()
                // After the Mac wakes, the HAL can hand back stale object IDs
                // ('!obj'), a not-yet-running device ('stop'), or a generic
                // hiccup — transient states that clear once it settles. Retry
                // with escalating backoff before showing a permanent banner.
                // We loop in place rather than re-`enqueue`-ing because this
                // already runs inside the FIFO serializer; re-entering it would
                // deadlock on `inFlight`. Holding the queue across the short
                // sleep is correct — coalesced wake/device-change triggers
                // queue behind us and find us already `.running`.
                if Self.isTransientHALError(error), attempt < Self.maxStartRetries {
                    attempt += 1
                    let delayMS = 200 << (attempt - 1)   // 200, 400, 800 ms
                    log.info("Transient HAL error on tap start (\(String(describing: error), privacy: .public)) — retry \(attempt)/\(Self.maxStartRetries) in \(delayMS) ms")
                    try? await Task.sleep(nanoseconds: UInt64(delayMS) * 1_000_000)
                    continue
                }
                state = .failed(String(describing: error))
                log.error("CATapEngine start failed: \(String(describing: error))")
                return
            }
        }
    }

    /// Post-wake / device-settling HAL failures: the HAL handed back a
    /// stale or not-yet-ready object rather than a hard, permanent error.
    /// These clear once the hardware settles, so `performStart` retries
    /// with backoff instead of dropping straight to a `.failed` banner.
    /// Mirrors the AVAudioEngine.start retry in `SherlockEQAudioEngine`.
    private static func isTransientHALError(_ error: Error) -> Bool {
        guard let tapError = error as? TapError, let status = tapError.osStatus else {
            return false
        }
        return transientHALStatuses.contains(status)
    }

    private static let transientHALStatuses: Set<OSStatus> = [
        OSStatus(kAudioHardwareBadObjectError),        // '!obj' (560947818) — stale object ID after wake
        OSStatus(kAudioHardwareBadDeviceError),        // '!dev' — device handle gone stale
        OSStatus(kAudioHardwareNotRunningError),       // 'stop' — HAL/device not yet running
        OSStatus(kAudioHardwareUnspecifiedError),      // 'what' — generic post-wake hiccup
        OSStatus(kAudioHardwareIllegalOperationError), // 'nope' (1852797029) — can't act in this context
    ]

    /// Consecutive transient-failure retries before the banner surfaces.
    private static let maxStartRetries = 3

    // MARK: - Build

    /// Result of the off-main CoreAudio prep step. Carries every value the
    /// main-actor `applyTapPrep` needs to wire up the source nodes without
    /// re-entering CoreAudio.
    private struct TapPrepResult {
        let outputDeviceID: AudioDeviceID
        let outputDeviceName: String
        let outputDeviceUID: String
        let outputDeviceIsBuiltIn: Bool
        let ownProcessObjectID: AudioObjectID
        let tapID: AudioObjectID
        let aggregateDeviceID: AudioDeviceID
        let asbd: AudioStreamBasicDescription
        let deliveredRate: Double
        let tapChannelCount: Int
    }

    /// All of the synchronous CoreAudio calls that historically ran on
    /// `@MainActor`. Hoisted out to a `nonisolated static` so callers can
    /// dispatch it onto a detached task — a wedged HAL (post-sleep, stuck
    /// aggregate, disconnected DAC the system still thinks is present)
    /// blocks `AudioObjectGetPropertyData*` indefinitely, and on the main
    /// thread that froze app launch. See memory `coreaudio-sync-main-thread-hang`.
    /// Cleans up the tap / aggregate it created if a later step throws —
    /// `start()`'s catch can't free them because they never reached `self`.
    nonisolated private static func prepareTapAndAggregate() throws -> TapPrepResult {
        let outputDeviceID = try defaultOutputDeviceID()
        let outputDeviceName = (try? deviceName(outputDeviceID)) ?? "Device \(outputDeviceID)"
        let outputDeviceUID = try deviceUID(outputDeviceID)
        // Snapshot the device's mute state BEFORE our tap engages its mute, so
        // crash-recovery can tell "we muted it" (recover) from "the user had it
        // muted" (leave alone). See `TapMuteSentinel`.
        let preTapMuted = SystemVolumeController.muted(deviceID: outputDeviceID) ?? false
        // Must succeed: if the PID→ProcessObject lookup fails and we fall back
        // to 0, the tap excludes process 0 (not SherlockEQ), so the app's own
        // processed output is no longer excluded — it gets re-tapped and
        // re-processed into an audio feedback loop. `processObjectIDForCurrentPID`
        // already throws `processObjectLookupFailed` on a bad lookup; let it
        // propagate to `performStart`'s catch → `.failed`, which is the correct,
        // visible outcome rather than a silent loop.
        let ownProcessObjectID = try processObjectIDForCurrentPID()

        // Global tap, excluding our own process to prevent the
        // AVAudioEngine output → tap → output feedback loop.
        let tapDescription = CATapDescription(
            stereoGlobalTapButExcludeProcesses: [ownProcessObjectID]
        )
        tapDescription.name = "SherlockEQ-Tap"
        tapDescription.isPrivate = false
        // Mute the original output path while the tap is being read so the user
        // hears only the AVAudioEngine-processed version, not original + ours.
        // If our engine ever stalls, the original path comes back automatically.
        tapDescription.muteBehavior = CATapMuteBehavior.mutedWhenTapped

        var newTapID: AUAudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw TapError.tapCreationFailed(tapStatus)
        }

        let tapUID: String
        do {
            tapUID = try tapUIDString(newTapID)
        } catch {
            AudioHardwareDestroyProcessTap(newTapID)
            throw error
        }

        let aggUID = "com.shawnbrown.SherlockEQ.aggregate.\(UUID().uuidString)"
        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "SherlockEQ Aggregate",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceTapAutoStartKey as String: 1,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: 1
                ]
            ]
        ]

        var newAggID: AudioDeviceID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &newAggID)
        guard aggStatus == noErr, newAggID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(newTapID)
            throw TapError.aggregateCreationFailed(aggStatus)
        }

        let asbd: AudioStreamBasicDescription
        let deliveredRate: Double
        do {
            asbd = try inputStreamFormat(newAggID)
            deliveredRate = try nominalSampleRate(outputDeviceID)
        } catch {
            AudioHardwareDestroyAggregateDevice(newAggID)
            AudioHardwareDestroyProcessTap(newTapID)
            throw error
        }

        // Ask the tap object how many channels IT contributes, so the IOProc
        // can locate the tap as the trailing slice rather than assuming a
        // stereo pair. Best-effort: a query failure falls back to 2 (our tap
        // is always a stereo global tap), preserving prior behaviour. Clamp
        // to at least 1 so the IOProc arithmetic can't underflow.
        let tapChannels = max(1, Int((try? tapStreamFormat(newTapID))?.mChannelsPerFrame ?? 2))

        // Tap + aggregate are live and the mute is engaged. Persist the
        // recovery marker now; a clean `tearDownSync` clears it. If the
        // process dies before that, the next launch finds this marker and
        // unmutes (see `TapMuteSentinel`).
        TapMuteSentinel.markActive(deviceUID: outputDeviceUID, preTapMuted: preTapMuted)

        return TapPrepResult(
            outputDeviceID: outputDeviceID,
            outputDeviceName: outputDeviceName,
            outputDeviceUID: outputDeviceUID,
            outputDeviceIsBuiltIn: isBuiltInOutput(outputDeviceID),
            ownProcessObjectID: ownProcessObjectID,
            tapID: newTapID,
            aggregateDeviceID: newAggID,
            asbd: asbd,
            deliveredRate: deliveredRate,
            tapChannelCount: tapChannels
        )
    }

    /// Main-actor counterpart to `prepareTapAndAggregate`. Touches no
    /// CoreAudio property APIs — only AVAudioFormat / source-node setup
    /// and assignment to `@Published` / instance state. If this throws,
    /// the tap / aggregate created by the prep step are still owned by
    /// `self` (via the assignments below) and will be released by the
    /// caller's `tearDown()`.
    private func applyTapPrep(_ prep: TapPrepResult) throws {
        currentOutputDeviceID = prep.outputDeviceID
        currentOutputDeviceName = prep.outputDeviceName
        currentOutputDeviceUID = prep.outputDeviceUID
        currentOutputDeviceIsBuiltIn = prep.outputDeviceIsBuiltIn
        excludedProcessObjectID.set(Int64(prep.ownProcessObjectID))
        tapID = prep.tapID
        aggregateDeviceID = prep.aggregateDeviceID

        // Read the tap stream format off the aggregate's input scope.
        // **Note**: `format.sampleRate` reports the *tap source* rate, not
        // the rate the IOProc will deliver. With drift compensation on,
        // the aggregate SRCs to the output device's rate before the IOProc
        // sees a sample. We stamp the source-node format and ring at the
        // **output rate** so AVAudioEngine consumes samples at the cadence
        // they actually arrive. See memory `audio-engine-sr-mismatch`.
        var asbd = prep.asbd
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw TapError.formatUnsupported
        }
        tapFormat = format
        tapChannelCount = prep.tapChannelCount

        let deliveredRate = prep.deliveredRate

        // ~250ms headroom per channel ring, sized in delivered frames.
        let ringCapacity = max(4096, Int(deliveredRate) / 4)
        let leftRing = TapRingBuffer(capacityFrames: ringCapacity)
        let rightRing = TapRingBuffer(capacityFrames: ringCapacity)
        self.leftRing = leftRing
        self.rightRing = rightRing

        // Source nodes emit stereo Float32 non-interleaved at the delivered
        // (output) rate — not the ASBD's claimed tap rate.
        let stereoFormat = AVAudioFormat(
            standardFormatWithSampleRate: deliveredRate,
            channels: 2
        )!
        sourceFormat = stereoFormat

        let leftCounter = leftSourceFramesOut
        let rightCounter = rightSourceFramesOut
        let outPeak = sourceOutputPeakMilli

        let sourceSR = stereoFormat.sampleRate
        let preIngest = self.preIngest    // strong capture — bare class, no actor
        // Scratch for the stereo (L+R)/2 pre-EQ input ghost. Both render blocks
        // capture it strongly; it lives as long as the source nodes. Sized to
        // the ring capacity, which already bounds any render slice.
        let preMix = StereoPreMix(capacity: ringCapacity)

        // Capture cascades strongly so the render block reads them
        // without an isolation hop. They live for the engine's lifetime;
        // safe to hold across the block's lifetime.
        let lEQ = leftEQCascade
        let rEQ = rightEQCascade

        // Dynamic stage runs right after the static cascade, on the same
        // captured-strongly basis. Stamp it at the delivered (output) rate
        // — the same rate context the cascades get via setBands — so its
        // detector + bell coefficients use the correct Nyquist.
        let lDyn = leftDynamics
        let rDyn = rightDynamics
        lDyn.setSampleRate(sourceSR)
        rDyn.setSampleRate(sourceSR)

        // Stage-A (AutoEQ) cascades + adaptive processors, same strong-
        // capture basis. The adaptive filterbank's crossovers are stamped
        // at the delivered rate here — the render block isn't running yet.
        let lPre = leftAutoEQCascade
        let rPre = rightAutoEQCascade
        let lAdaptive = leftAdaptive
        let rAdaptive = rightAdaptive
        lAdaptive.setSampleRate(sourceSR)
        rAdaptive.setSampleRate(sourceSR)

        leftSourceNode = AVAudioSourceNode(format: stereoFormat) { [weak leftRing] _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            // Never trust the render block's frameCount argument alone — some
            // transient HAL conditions (sample-rate change, device switch,
            // post-sleep wedge; see CATapEngine's IOProc comments) can hand us
            // a stale/mismatched AudioBufferList. Clamp once, up front, and
            // use this value for every read/write against these buffers in
            // this callback, not just the ring fill.
            let safeFrames = Self.safeFrameCount(frameCount, in: buffers)
            let status = Self.fillFromMonoRing(
                ring: leftRing,
                channelIndex: 0,
                abl: audioBufferList,
                frameCount: safeFrames
            )
            // Pre-EQ input spectrum side-channel: average this slice's RAW left
            // samples with the right block's stashed raw samples — BEFORE the EQ
            // cascade mutates them in place — so the canvas "input" ghost shows
            // the unprocessed stereo program and diverges from the post-EQ
            // output (the mainMixer tap) by the EQ curve. (L+R)/2 matches the
            // output overlay's mono mixing, keeping both on one level basis.
            // Snapshot under the lock (bumps the entry counter atomically with
            // the read), then invoke OUTSIDE the lock so main-thread writers
            // don't get stalled waiting for the callback to run.
            if let callback = preIngest.snapshotCallbackForRender(),
               let lPtr = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                let (mono, n) = preMix.mixedMono(left: lPtr, count: safeFrames)
                callback(mono, n, sourceSR)
                preIngest.recordCallbackInvocation()
            }
            // EQ on the L channel only (R is held at 0 by the fill).
            // Order (phase4 §4.1): AutoEQ (headphone-flatten) → Adaptive
            // Correction (level-following, nonlinear — placement matters)
            // → static cascade (steady correction when applicable + user
            // EQ + notch + trim) → Listening Comfort dynamics.
            if buffers.count > 0,
               let lPtr = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                lPre.process(samples: lPtr, count: safeFrames)
                lAdaptive.process(lPtr, frameCount: safeFrames)
                lEQ.process(samples: lPtr, count: safeFrames)
                lDyn.process(samples: lPtr, count: safeFrames)
            }
            leftCounter.add(safeFrames)
            Self.recordPeak(abl: audioBufferList, frameCount: frameCount, into: outPeak)
            return status
        }
        rightSourceNode = AVAudioSourceNode(format: stereoFormat) { [weak rightRing] _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let safeFrames = Self.safeFrameCount(frameCount, in: buffers)
            let status = Self.fillFromMonoRing(
                ring: rightRing,
                channelIndex: 1,
                abl: audioBufferList,
                frameCount: safeFrames
            )
            // Stash the RAW right-channel pre-EQ samples for the left block's
            // (L+R)/2 input ghost, BEFORE the EQ cascade mutates them in place.
            if buffers.count >= 2,
               let rPtr = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                preMix.stashRight(rPtr, count: safeFrames)
            }
            // EQ on the R channel only (L is held at 0 by the fill).
            if buffers.count >= 2,
               let rPtr = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                rPre.process(samples: rPtr, count: safeFrames)
                rAdaptive.process(rPtr, frameCount: safeFrames)
                rEQ.process(samples: rPtr, count: safeFrames)
                rDyn.process(samples: rPtr, count: safeFrames)
            }
            rightCounter.add(safeFrames)
            Self.recordPeak(abl: audioBufferList, frameCount: frameCount, into: outPeak)
            return status
        }
    }

    /// Clamp a render block's `frameCount` argument to the smallest byte-size-
    /// derived capacity among the delivered buffers, so a mismatched/stale
    /// `AudioBufferList` can't drive an overrun in any of the processing that
    /// follows in the same callback. Under `AVAudioSourceNode`'s normal
    /// contract this is a no-op (frameCount always fits); it only clamps
    /// during the abnormal transient conditions noted above. No allocation —
    /// a fixed-size scan over (typically 2) buffers.
    private static func safeFrameCount(
        _ frameCount: AVAudioFrameCount, in buffers: UnsafeMutableAudioBufferListPointer
    ) -> Int {
        var frames = Int(frameCount)
        for buf in buffers {
            frames = min(frames, Int(buf.mDataByteSize) / MemoryLayout<Float>.size)
        }
        return frames
    }

    /// Render-thread helper: scan the just-filled abl and store the max abs sample
    /// as a rolling peak (in milli-units, 0…1000).
    private static func recordPeak(
        abl: UnsafeMutablePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount,
        into counter: AudioCounter
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        var peak: Float = 0
        for buf in buffers {
            guard let ptr = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<n {
                let a = abs(ptr[i])
                if a > peak { peak = a }
            }
        }
        counter.set(Int64(peak * 1000))
    }

    /// Render-thread helper: read mono samples from `ring` into one channel of the
    /// stereo `abl`, zero the other channel. Pad short reads with silence.
    /// `frameCount` must already be clamped to the buffers' actual capacity —
    /// see `safeFrameCount(_:in:)`, computed once by the caller for the whole
    /// render callback.
    private static func fillFromMonoRing(
        ring: TapRingBuffer?,
        channelIndex: Int,
        abl: UnsafeMutablePointer<AudioBufferList>,
        frameCount: Int
    ) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        guard buffers.count >= 2 else { return noErr }
        let bytesPerFrame = MemoryLayout<Float>.size

        let otherChannel = 1 - channelIndex
        if let otherPtr = buffers[otherChannel].mData {
            memset(otherPtr, 0, Int(buffers[otherChannel].mDataByteSize))
        }

        guard let activePtr = buffers[channelIndex].mData?.assumingMemoryBound(to: Float.self) else {
            return noErr
        }
        let totalFrames = frameCount
        let filled = ring?.read(into: activePtr, frameCount: totalFrames) ?? 0
        if filled < totalFrames {
            let tailBytes = (totalFrames - filled) * bytesPerFrame
            memset(activePtr.advanced(by: filled), 0, tailBytes)
        }
        return noErr
    }

    /// Resolve a global channel index within an aggregate's input ABL —
    /// which may mix interleaved and planar buffers — and deinterleave that
    /// one channel into `ring`, accumulating the channel's peak. Returns the
    /// frame count written (0 if the channel index isn't present). RT-safe:
    /// no allocation, just index arithmetic and the ring's strided copy.
    private static func emitTapChannel(
        abl: UnsafeMutableAudioBufferListPointer,
        globalChannel: Int,
        into ring: TapRingBuffer,
        peak: inout Float
    ) -> Int {
        var base = 0
        for b in abl {
            let ch = Int(b.mNumberChannels)
            if ch == 0 { continue }
            if globalChannel < base + ch, let raw = b.mData {
                let within = globalChannel - base
                let frames = Int(b.mDataByteSize) / (MemoryLayout<Float>.size * ch)
                if frames <= 0 { return 0 }
                let ptr = raw.assumingMemoryBound(to: Float.self)
                var i = within
                let n = frames * ch
                while i < n {
                    let a = abs(ptr[i])
                    if a > peak { peak = a }
                    i += ch
                }
                ring.writeChannel(from: ptr, frameCount: frames, channelIndex: within, channelCount: ch)
                return frames
            }
            base += ch
        }
        return 0
    }

    // MARK: - IO

    private func startIO() throws {
        guard let leftRing, let rightRing else { throw TapError.notConfigured }
        var procID: AudioDeviceIOProcID?
        let leftRef = Unmanaged.passUnretained(leftRing)
        let rightRef = Unmanaged.passUnretained(rightRing)
        let counterRef = Unmanaged.passUnretained(tapFramesIn)

        let peakRef = Unmanaged.passUnretained(ringInputPeakMilli)
        let layoutCountRef = Unmanaged.passUnretained(ioProcBufferCount)
        let layoutChannelsRef = Unmanaged.passUnretained(ioProcFirstChannels)
        let layoutBytesRef = Unmanaged.passUnretained(ioProcFirstByteSize)
        let callsRef = Unmanaged.passUnretained(ioProcCalls)

        // Capture the tap's real channel count by value — the block can't hop
        // back to the actor to read `self.tapChannelCount` on the audio thread.
        let tapChannels = tapChannelCount

        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateDeviceID,
            nil
        ) { _, inInputData, _, _, _ in
            callsRef.takeUnretainedValue().add(1)
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            layoutCountRef.takeUnretainedValue().set(Int64(abl.count))
            guard let first = abl.first else { return }
            layoutChannelsRef.takeUnretainedValue().set(Int64(first.mNumberChannels))
            layoutBytesRef.takeUnretainedValue().set(Int64(first.mDataByteSize))

            let leftBuf = leftRef.takeUnretainedValue()
            let rightBuf = rightRef.takeUnretainedValue()
            let peakBuf = peakRef.takeUnretainedValue()

            // The process tap occupies the LAST `tapChannels` channels of the
            // aggregate's input scope. CoreAudio appends tap channels after
            // each sub-device's channels, so when the output device is itself
            // an interface with hardware inputs (e.g. a RODECaster), those
            // input channels appear FIRST and the tap follows — reading
            // channels 0-1 there grabs the device's live input (static) instead
            // of the captured system audio. `tapChannels` is the tap's own
            // reported channel count, so we key off the trailing slice rather
            // than assuming a stereo pair: a MONO tap sitting behind hardware
            // inputs reads its single channel into both ears instead of pulling
            // a live input channel into the left ear. For an output-only device
            // the tap is the only input, so the trailing slice IS channels
            // 0-1 and behaviour is unchanged. Buffers may be interleaved (one
            // buffer, N channels) or planar (N buffers, one channel each);
            // emitTapChannel resolves a global channel index across both.
            var totalChannels = 0
            for b in abl { totalChannels += Int(b.mNumberChannels) }
            guard totalChannels >= 1 else { return }

            // Clamp the tap slice to what's actually present, then take its
            // first two channels as L/R (front pair for a multichannel tap,
            // the same single channel for a mono tap).
            let slice = max(1, min(tapChannels, totalChannels))
            let tapStart = totalChannels - slice
            let tapLeft = tapStart
            let tapRight = slice >= 2 ? tapStart + 1 : tapStart

            var peak: Float = 0
            let framesL = Self.emitTapChannel(abl: abl, globalChannel: tapLeft, into: leftBuf, peak: &peak)
            let framesR = Self.emitTapChannel(abl: abl, globalChannel: tapRight, into: rightBuf, peak: &peak)
            let frames = max(framesL, framesR)
            if frames > 0 { counterRef.takeUnretainedValue().add(frames) }

            peakBuf.set(Int64(peak * 1000))
        }
        guard ioStatus == noErr, let procID else {
            throw TapError.ioProcCreationFailed(ioStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
        guard startStatus == noErr else {
            throw TapError.ioProcStartFailed(startStatus)
        }
    }

    // MARK: - Device-change listener

    /// Install the system-wide default-output-device listener (fires
    /// when the user picks a different output in System Settings) plus
    /// per-device listeners on the currently-bound device for stream
    /// configuration (channel-layout change) and nominal sample rate
    /// (rate change in Audio MIDI Setup). All three flow through
    /// `handleDeviceTopologyChanged` which rebuilds the graph against
    /// the new shape.
    private func installDefaultOutputDeviceListener() {
        // Idempotent — re-bind only if not already present for the
        // current target. Default-output listener targets the system
        // object; the per-device listeners target the current device,
        // so they need re-installing whenever the device binding moves.
        installSystemListener(
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ) { [weak self] in
            await self?.handleDefaultOutputDeviceChanged()
        }
        installCurrentDeviceConfigListeners()
    }

    /// Re-install the per-device listeners against `currentOutputDeviceID`.
    /// Called after start() and after a device change so the listeners
    /// always point at the device we're currently tapping.
    private func installCurrentDeviceConfigListeners() {
        // Drop any prior per-device listeners — they're targeted at
        // the previous device's ID and would never fire on the new one.
        removeListeners(matching: { $0.target != AudioObjectID(kAudioObjectSystemObject) })

        let deviceID = currentOutputDeviceID
        guard deviceID != kAudioObjectUnknown else { return }
        installDeviceListener(deviceID: deviceID, selector: kAudioDevicePropertyStreamConfiguration) { [weak self] in
            await self?.handleDeviceTopologyChanged(reason: "stream config")
        }
        installDeviceListener(deviceID: deviceID, selector: kAudioDevicePropertyNominalSampleRate) { [weak self] in
            await self?.handleDeviceTopologyChanged(reason: "sample rate")
        }
    }

    private func installSystemListener(
        selector: AudioObjectPropertySelector,
        action: @escaping @Sendable () async -> Void
    ) {
        let target = AudioObjectID(kAudioObjectSystemObject)
        guard !installedListeners.contains(where: { $0.target == target && $0.selector == selector }) else { return }
        addListener(target: target, selector: selector, action: action)
    }

    private func installDeviceListener(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        action: @escaping @Sendable () async -> Void
    ) {
        addListener(target: deviceID, selector: selector, action: action)
    }

    private func addListener(
        target: AudioObjectID,
        selector: AudioObjectPropertySelector,
        action: @escaping @Sendable () async -> Void,
        attempt: Int = 0
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in await action() }
        }
        let status = AudioObjectAddPropertyListenerBlock(target, &address, DispatchQueue.main, block)
        if status == noErr {
            installedListeners.append(InstalledListener(target: target, selector: selector, block: block))
            return
        }
        // A transient HAL status here (a stale object right after wake)
        // would otherwise leave us silently deaf to later device / rate
        // changes — the install isn't on a throwing path, so the tap still
        // reaches `.running`, and nothing ever re-arms the listener. Retry
        // with the same backoff the start path uses. (A failed install
        // registers nothing, so there's no leaked block to remove first.)
        if Self.transientHALStatuses.contains(status), attempt < Self.maxStartRetries {
            let delayMS = 200 << attempt   // 200, 400, 800 ms
            log.info("Listener install failed (sel \(selector), target \(target), status \(status)) — retry \(attempt + 1)/\(Self.maxStartRetries) in \(delayMS) ms")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delayMS) * 1_000_000)
                guard let self else { return }
                // Bail if the device moved under us (the retry targets the
                // old device's ID) or a later pass already (re)installed it.
                let stillRelevant = target == AudioObjectID(kAudioObjectSystemObject)
                    || target == self.currentOutputDeviceID
                guard stillRelevant else { return }
                guard !self.installedListeners.contains(where: {
                    $0.target == target && $0.selector == selector
                }) else { return }
                self.addListener(target: target, selector: selector, action: action, attempt: attempt + 1)
            }
            return
        }
        log.error("Failed to install listener (sel \(selector), target \(target)): \(status) — giving up after \(attempt + 1) attempt(s)")
    }

    private func removeListeners(matching predicate: (InstalledListener) -> Bool) {
        var keep: [InstalledListener] = []
        for listener in installedListeners {
            if predicate(listener) {
                var address = AudioObjectPropertyAddress(
                    mSelector: listener.selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                _ = AudioObjectRemovePropertyListenerBlock(listener.target, &address, DispatchQueue.main, listener.block)
            } else {
                keep.append(listener)
            }
        }
        installedListeners = keep
    }

    private func handleDefaultOutputDeviceChanged() async {
        // Guard runs *inside* the serialized block so a burst of
        // listener fires doesn't queue up redundant rebuilds — by the
        // time the second one runs, `currentOutputDeviceID` has
        // already been updated and the guard short-circuits.
        await enqueue { [weak self] in
            guard let self else { return }
            guard
                let newID = try? Self.defaultOutputDeviceID(),
                newID != self.currentOutputDeviceID
            else { return }
            self.log.info("Default output device changed: \(self.currentOutputDeviceID) → \(newID)")
            self.tearDownTapAndAggregate()
            await self.performStart()
            self.onOutputDeviceChanged?(self.currentOutputDeviceID)
        }
    }

    /// Same shape as a device-change for the AVAudioEngine graph: the
    /// stream layout or nominal rate of the device we're tapping has
    /// changed under us, and the aggregate + source-node formats are
    /// now stale. Rebuild against the new shape.
    private func handleDeviceTopologyChanged(reason: String) async {
        await enqueue { [weak self] in
            guard let self else { return }
            self.log.info("Output device topology change (\(reason, privacy: .public)) — rebuilding")
            self.tearDownTapAndAggregate()
            await self.performStart()
            self.onOutputDeviceChanged?(self.currentOutputDeviceID)
        }
    }

    // MARK: - Teardown

    private func tearDown() {
        tearDownTapAndAggregate()
        removeListeners(matching: { _ in true })
        leftSourceNode = nil
        rightSourceNode = nil
        tapFormat = nil
        sourceFormat = nil
        leftRing = nil
        rightRing = nil
    }

    private func tearDownTapAndAggregate() {
        // Drop per-device listeners since the device binding is going
        // away (or about to be replaced). The system-object default-
        // output listener stays — it's how we'll be told about the
        // user picking a new device next.
        removeListeners(matching: { $0.target != AudioObjectID(kAudioObjectSystemObject) })
        Self.tearDownSync(
            tapID: tapID,
            aggregateDeviceID: aggregateDeviceID,
            ioProcID: ioProcID
        )
        tapID = kAudioObjectUnknown
        aggregateDeviceID = kAudioObjectUnknown
        ioProcID = nil
    }

    nonisolated private static func tearDownSync(
        tapID: AudioObjectID,
        aggregateDeviceID: AudioDeviceID,
        ioProcID: AudioDeviceIOProcID?
    ) {
        if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        // Clean teardown: the mute is released, so drop the recovery marker.
        // (Harmless if it was already clear.)
        TapMuteSentinel.clear()
    }

    // MARK: - Errors

    enum TapError: Error, CustomStringConvertible {
        case tapCreationFailed(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case ioProcStartFailed(OSStatus)
        case defaultOutputUnavailable(OSStatus)
        case deviceUIDUnavailable(OSStatus)
        case tapUIDUnavailable(OSStatus)
        case formatUnavailable(OSStatus)
        case formatUnsupported
        case processObjectLookupFailed(OSStatus)
        case notConfigured

        var description: String {
            switch self {
            case .tapCreationFailed(let s): return "AudioHardwareCreateProcessTap failed (\(s))"
            case .aggregateCreationFailed(let s): return "AudioHardwareCreateAggregateDevice failed (\(s))"
            case .ioProcCreationFailed(let s): return "AudioDeviceCreateIOProcIDWithBlock failed (\(s))"
            case .ioProcStartFailed(let s): return "AudioDeviceStart failed (\(s))"
            case .defaultOutputUnavailable(let s): return "Default output query failed (\(s))"
            case .deviceUIDUnavailable(let s): return "Device UID query failed (\(s))"
            case .tapUIDUnavailable(let s): return "Tap UID query failed (\(s))"
            case .formatUnavailable(let s): return "Stream format query failed (\(s))"
            case .formatUnsupported: return "Stream format could not be expressed as AVAudioFormat"
            case .processObjectLookupFailed(let s): return "PID→AudioObjectID lookup failed (\(s))"
            case .notConfigured: return "Tap not configured"
            }
        }

        /// The underlying CoreAudio OSStatus, when the case carries one.
        /// Used to classify transient HAL failures for the start retry.
        var osStatus: OSStatus? {
            switch self {
            case .tapCreationFailed(let s), .aggregateCreationFailed(let s),
                 .ioProcCreationFailed(let s), .ioProcStartFailed(let s),
                 .defaultOutputUnavailable(let s), .deviceUIDUnavailable(let s),
                 .tapUIDUnavailable(let s), .formatUnavailable(let s),
                 .processObjectLookupFailed(let s):
                return s
            case .formatUnsupported, .notConfigured:
                return nil
            }
        }
    }
}

// MARK: - Core Audio property helpers

extension CATapEngine {

    /// `nonisolated` because the body only does CoreAudio C calls and
    /// touches no instance state — any caller (main or background)
    /// can run it. `AudioObjectGetPropertyData` for the default-output
    /// selector is the same family of calls that wedged at launch via
    /// `allOutputDevices`, so keeping these helpers safe to dispatch
    /// off-main is hygiene against future regressions.
    nonisolated static func defaultOutputDeviceID() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size, &deviceID
        )
        guard status == noErr else { throw TapError.defaultOutputUnavailable(status) }
        return deviceID
    }

    nonisolated static func deviceName(_ deviceID: AudioDeviceID) throws -> String {
        // CoreAudio writes a +1-retained CFStringRef into the out-pointer.
        // Receive via Unmanaged<CFString>? so we can `takeRetainedValue()`
        // explicitly; passing `&someCFString` where someCFString is a value
        // type warns because CFString may carry an object reference.
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr, let cf = name?.takeRetainedValue() else {
            throw TapError.deviceUIDUnavailable(status)
        }
        return cf as String
    }

    /// Output device's nominal sample rate. **This is the rate the IOProc
    /// actually delivers** when the aggregate runs with drift compensation
    /// on — see memory `audio-engine-sr-mismatch` (the ASBD on the
    /// aggregate's input scope still reports the tap's source rate, which
    /// is misleading: drift comp silently SRCs to the output rate before
    /// the IOProc fires). Used to stamp the source-node format so
    /// AVAudioEngine consumes samples at the same cadence they arrive.
    nonisolated static func nominalSampleRate(_ deviceID: AudioDeviceID) throws -> Double {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { throw TapError.formatUnavailable(status) }
        return rate
    }

    nonisolated static func deviceUID(_ deviceID: AudioDeviceID) throws -> String {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let cf = uid?.takeRetainedValue() else {
            throw TapError.deviceUIDUnavailable(status)
        }
        return cf as String
    }

    /// True when the device's transport is the Mac's built-in speakers —
    /// the one output where a headphone correction curve is categorically
    /// wrong. Best-effort: an unreadable transport reads as "not built-in"
    /// (the mismatch warning then just uses its normal copy).
    nonisolated static func isBuiltInOutput(_ deviceID: AudioDeviceID) -> Bool {
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        return status == noErr && transport == kAudioDeviceTransportTypeBuiltIn
    }

    /// Lightweight descriptor for the output-device picker.
    struct OutputDevice: Hashable, Identifiable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    /// Enumerate every device that can act as an output. Skips devices
    /// without output streams (mics, aggregate-only inputs) and any
    /// device whose UID we can't read.
    ///
    /// `nonisolated` because the body only does CoreAudio C calls and
    /// touches no instance state — and the underlying
    /// `AudioObjectGetPropertyDataSize` can block when the audio HAL
    /// is in a stuck state (post-sleep wedge, disconnected USB DAC
    /// the system still thinks is present). Running it on the main
    /// thread froze the app at launch when Profile Detail's
    /// `.onAppear` fired before the window was visible.
    nonisolated static func allOutputDevices() -> [OutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id in
            guard hasOutputStream(id) else { return nil }
            guard let uid = try? Self.deviceUID(id), !uid.isEmpty else { return nil }
            let name = (try? Self.deviceName(id)) ?? "Device \(id)"
            guard isSelectableOutput(uid: uid, name: name) else { return nil }
            return OutputDevice(id: id, uid: uid, name: name)
        }
    }

    /// True for devices a user could meaningfully pick as their speakers —
    /// false for the transient plumbing CoreAudio exposes alongside real
    /// hardware. Those have output streams and valid UIDs, so they'd otherwise
    /// surface as bogus picker buttons (e.g. the amber `?` in the screenshot).
    nonisolated private static func isSelectableOutput(uid: String, name: String) -> Bool {
        // macOS spins up "CADefaultDeviceAggregate-<pid>-<n>" devices to wrap
        // the current default output; they come and go with audio sessions and
        // are never a real speaker the user chose.
        if uid.hasPrefix("CADefaultDeviceAggregate") || name.hasPrefix("CADefaultDeviceAggregate") {
            return false
        }
        // SherlockEQ's own tap aggregate is created private (so it shouldn't
        // enumerate), but filter by UID prefix as belt-and-suspenders.
        if uid.hasPrefix("com.shawnbrown.SherlockEQ.aggregate") {
            return false
        }
        return true
    }

    /// True when a device exposes at least one output stream — filters
    /// microphones and input-only aggregates out of the picker.
    nonisolated private static func hasOutputStream(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

    nonisolated static func tapUIDString(_ tapID: AudioObjectID) throws -> String {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &uid)
        guard status == noErr, let cf = uid?.takeRetainedValue() else {
            throw TapError.tapUIDUnavailable(status)
        }
        return cf as String
    }

    /// The tap object's own stream format. `mChannelsPerFrame` is the
    /// authoritative channel count the tap injects into the aggregate's
    /// input scope — used to locate the tap channels without assuming a
    /// stereo pair. Throws on a failed query so the caller can fall back.
    nonisolated static func tapStreamFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else { throw TapError.formatUnavailable(status) }
        return asbd
    }

    nonisolated static func inputStreamFormat(_ deviceID: AudioDeviceID) throws -> AudioStreamBasicDescription {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd)
        guard status == noErr else { throw TapError.formatUnavailable(status) }
        return asbd
    }

    /// Translate our own PID into a Core Audio process-object ID so we can exclude
    /// ourselves from the global tap (preventing AVAudioEngine output → tap → output feedback).
    nonisolated static func processObjectIDForCurrentPID() throws -> AudioObjectID {
        var pid = pid_t(getpid())
        var processObjectID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size), &pid,
            &size, &processObjectID
        )
        guard status == noErr, processObjectID != 0 else {
            throw TapError.processObjectLookupFailed(status)
        }
        return processObjectID
    }
}
