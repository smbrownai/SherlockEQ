import Foundation
import AVFoundation
import Combine
import CoreAudio
import CoreGraphics
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

    /// Re-check Screen Recording permission. macOS lets the user revoke
    /// it in System Settings mid-session; when that happens the IOProc
    /// silently delivers zeros and nothing in our state changes. Call
    /// this when the app becomes active (the natural moment the user
    /// has returned from toggling something in Settings) — if the
    /// permission has dropped while we thought we were running, flip
    /// to `.failed` and tear down so the user sees the same actionable
    /// error message as the first-time-denied path.
    func recheckScreenCapturePermission() {
        // Only meaningful while we believed we were tapping. In other
        // states this is either irrelevant (.idle, .awaitingPermission,
        // .permissionDenied) or already handled (.failed, .starting).
        guard case .running = state else { return }
        guard !CGPreflightScreenCaptureAccess() else { return }
        log.error("Screen Recording permission revoked mid-session — tearing tap down")
        state = .failed("""
            Screen & System Audio Recording permission was revoked. \
            Open System Settings → Privacy & Security → Screen & System Audio \
            Recording, re-enable SherlockEQ, then quit and relaunch the app.
            """)
        tearDownTapAndAggregate()
    }

    func requestPermissionAndStart() async {
        state = .awaitingPermission

        // 1. Microphone (covers the audio-input entitlement).
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        permissionGranted = micGranted
        guard micGranted else {
            state = .permissionDenied
            log.error("Microphone permission denied")
            return
        }

        // 2. Screen & System Audio Recording — required for CATap to deliver
        //    audio from other processes on macOS 14.4+. The OS silently zeroes
        //    tap data without it, which is exactly what we just spent hours
        //    diagnosing. Request triggers the system dialog the first time;
        //    after that the user must grant in System Settings manually.
        if !CGPreflightScreenCaptureAccess() {
            log.info("Screen capture access not granted — requesting...")
            _ = CGRequestScreenCaptureAccess()   // shows dialog OR no-ops if previously denied
            if !CGPreflightScreenCaptureAccess() {
                state = .failed("""
                    Screen & System Audio Recording permission is required. \
                    Open System Settings → Privacy & Security → Screen & System Audio \
                    Recording, enable SherlockEQ, then quit and relaunch the app.
                    """)
                return
            }
        }

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
        do {
            let prep = try await Task.detached(priority: .userInitiated) {
                try Self.prepareTapAndAggregate()
            }.value
            try applyTapPrep(prep)
            try startIO()
            installDefaultOutputDeviceListener()
            state = .running
            log.info("CATapEngine running on device \(self.currentOutputDeviceID)")
        } catch {
            state = .failed(String(describing: error))
            log.error("CATapEngine start failed: \(String(describing: error))")
            tearDown()
        }
    }

    // MARK: - Build

    /// Result of the off-main CoreAudio prep step. Carries every value the
    /// main-actor `applyTapPrep` needs to wire up the source nodes without
    /// re-entering CoreAudio.
    private struct TapPrepResult {
        let outputDeviceID: AudioDeviceID
        let outputDeviceName: String
        let ownProcessObjectID: AudioObjectID
        let tapID: AudioObjectID
        let aggregateDeviceID: AudioDeviceID
        let asbd: AudioStreamBasicDescription
        let deliveredRate: Double
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
        let ownProcessObjectID = (try? processObjectIDForCurrentPID()) ?? 0

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

        return TapPrepResult(
            outputDeviceID: outputDeviceID,
            outputDeviceName: outputDeviceName,
            ownProcessObjectID: ownProcessObjectID,
            tapID: newTapID,
            aggregateDeviceID: newAggID,
            asbd: asbd,
            deliveredRate: deliveredRate
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
        tapChannelCount = Int(format.channelCount)

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

        // Capture cascades strongly so the render block reads them
        // without an isolation hop. They live for the engine's lifetime;
        // safe to hold across the block's lifetime.
        let lEQ = leftEQCascade
        let rEQ = rightEQCascade

        leftSourceNode = AVAudioSourceNode(format: stereoFormat) { [weak leftRing] _, _, frameCount, audioBufferList -> OSStatus in
            let status = Self.fillFromMonoRing(
                ring: leftRing,
                channelIndex: 0,
                abl: audioBufferList,
                frameCount: frameCount
            )
            // EQ on the L channel only (R is held at 0 by the fill).
            // Pre-EQ spectrum side-channel reads the *post-EQ* signal
            // because that's what the user actually hears, matching the
            // post-EQ tap on the other side of the chain.
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            if buffers.count > 0,
               let lPtr = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                lEQ.process(samples: lPtr, count: Int(frameCount))
            }
            leftCounter.add(Int(frameCount))
            Self.recordPeak(abl: audioBufferList, frameCount: frameCount, into: outPeak)
            // Snapshot under the lock (bumps the entry counter atomically
            // with the read), then invoke OUTSIDE the lock so main-thread
            // writers don't get stalled waiting for the callback to run.
            if let callback = preIngest.snapshotCallbackForRender(),
               let lPtr = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                callback(lPtr, Int(frameCount), sourceSR)
                preIngest.recordCallbackInvocation()
            }
            return status
        }
        rightSourceNode = AVAudioSourceNode(format: stereoFormat) { [weak rightRing] _, _, frameCount, audioBufferList -> OSStatus in
            let status = Self.fillFromMonoRing(
                ring: rightRing,
                channelIndex: 1,
                abl: audioBufferList,
                frameCount: frameCount
            )
            // EQ on the R channel only (L is held at 0 by the fill).
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            if buffers.count >= 2,
               let rPtr = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                rEQ.process(samples: rPtr, count: Int(frameCount))
            }
            rightCounter.add(Int(frameCount))
            Self.recordPeak(abl: audioBufferList, frameCount: frameCount, into: outPeak)
            return status
        }
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
    private static func fillFromMonoRing(
        ring: TapRingBuffer?,
        channelIndex: Int,
        abl: UnsafeMutablePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount
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
        let totalFrames = Int(frameCount)
        let filled = ring?.read(into: activePtr, frameCount: totalFrames) ?? 0
        if filled < totalFrames {
            let tailBytes = (totalFrames - filled) * bytesPerFrame
            memset(activePtr.advanced(by: filled), 0, tailBytes)
        }
        return noErr
    }

    // MARK: - IO

    private func startIO() throws {
        guard let leftRing, let rightRing else { throw TapError.notConfigured }
        var procID: AudioDeviceIOProcID?
        let leftRef = Unmanaged.passUnretained(leftRing)
        let rightRef = Unmanaged.passUnretained(rightRing)
        let counterRef = Unmanaged.passUnretained(tapFramesIn)
        let channelCount = tapChannelCount

        let peakRef = Unmanaged.passUnretained(ringInputPeakMilli)
        let layoutCountRef = Unmanaged.passUnretained(ioProcBufferCount)
        let layoutChannelsRef = Unmanaged.passUnretained(ioProcFirstChannels)
        let layoutBytesRef = Unmanaged.passUnretained(ioProcFirstByteSize)
        let callsRef = Unmanaged.passUnretained(ioProcCalls)

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

            let isInterleaved = abl.count == 1 && first.mNumberChannels >= 2
            let leftBuf = leftRef.takeUnretainedValue()
            let rightBuf = rightRef.takeUnretainedValue()
            let peakBuf = peakRef.takeUnretainedValue()

            var peak: Float = 0

            if isInterleaved {
                guard let basePtr = first.mData else { return }
                let chCount = Int(first.mNumberChannels)
                let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * chCount)
                if frames <= 0 { return }
                let src = basePtr.assumingMemoryBound(to: Float.self)
                for i in 0..<(frames * chCount) {
                    let a = abs(src[i])
                    if a > peak { peak = a }
                }
                leftBuf.writeChannel(from: src, frameCount: frames, channelIndex: 0, channelCount: chCount)
                rightBuf.writeChannel(
                    from: src, frameCount: frames,
                    channelIndex: chCount > 1 ? 1 : 0, channelCount: chCount
                )
                counterRef.takeUnretainedValue().add(frames)
            } else {
                guard let lPtr = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                let frames = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
                if frames <= 0 { return }
                for i in 0..<frames {
                    let a = abs(lPtr[i])
                    if a > peak { peak = a }
                }
                leftBuf.write(from: lPtr, frameCount: frames)
                if abl.count > 1, let rPtr = abl[1].mData?.assumingMemoryBound(to: Float.self) {
                    for i in 0..<frames {
                        let a = abs(rPtr[i])
                        if a > peak { peak = a }
                    }
                    rightBuf.write(from: rPtr, frameCount: frames)
                } else {
                    rightBuf.write(from: lPtr, frameCount: frames)
                }
                _ = channelCount
                counterRef.takeUnretainedValue().add(frames)
            }

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
        action: @escaping @Sendable () async -> Void
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
        } else {
            log.error("Failed to install listener (sel \(selector), target \(target)): \(status)")
        }
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
            return OutputDevice(id: id, uid: uid, name: name)
        }
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
