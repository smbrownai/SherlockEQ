import Foundation
import AVFoundation
import Combine
import CoreAudio
import CoreGraphics
import OSLog

@available(macOS 14.2, *)
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
    @Published private(set) var currentOutputDeviceID: AudioDeviceID = kAudioObjectUnknown
    @Published private(set) var currentOutputDeviceName: String = "—"

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
    /// separate. AuditumEQAudioEngine reconfigures these via
    /// `setBands(...)` on every profile change.
    let leftEQCascade = BiquadCascade()
    let rightEQCascade = BiquadCascade()

    /// Format both source nodes emit (stereo, tap sample rate).
    private(set) var sourceFormat: AVAudioFormat?
    /// Tap stream descriptor — sample rate, channel count of the raw tap.
    private(set) var tapFormat: AVAudioFormat?

    var onOutputDeviceChanged: ((AudioDeviceID) -> Void)?

    /// Side-channel for the pre-EQ spectrum analyzer. We can't store this as
    /// a plain property on a @MainActor type and have the audio-thread render
    /// block read it — access from outside the actor returns stale state.
    /// A bare reference class with a single mutable property avoids the
    /// isolation hop entirely: the render block captures `preIngest`
    /// strongly, then reads its callback field directly each frame.
    let preIngest = PreSpectrumIngestSlot()

    /// Plain class holding a single nullable callback. Lives outside any
    /// actor so the audio thread can read its `callback` field without an
    /// isolation hop. Writers (AudioState) just assign to `.callback`.
    final class PreSpectrumIngestSlot {
        var callback: ((UnsafePointer<Float>, Int, Double) -> Void)?
        /// Bumped from the audio thread whenever the callback path runs.
        /// Racy on purpose — for diagnostics only.
        var renderBlockEntries: Int = 0
        var callbackInvocations: Int = 0
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
    /// Process object ID we excluded from the global tap (our own).
    let excludedProcessObjectID = AudioCounter()

    private let log = Logger(subsystem: "com.shawnbrown.AuditumEQ", category: "CATapEngine")

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    private var leftRing: TapRingBuffer?
    private var rightRing: TapRingBuffer?
    private var tapChannelCount: Int = 2

    private var deviceListenerInstalled = false

    deinit {
        Self.tearDownSync(
            tapID: tapID,
            aggregateDeviceID: aggregateDeviceID,
            ioProcID: ioProcID
        )
    }

    // MARK: - Public lifecycle

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
                    Recording, enable AuditumEQ, then quit and relaunch the app.
                    """)
                return
            }
        }

        await start()
    }

    func start() async {
        state = .starting
        do {
            try buildTapAndAggregate()
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

    func stop() {
        tearDown()
        state = .idle
    }

    // MARK: - Build

    private func buildTapAndAggregate() throws {
        let outputDeviceID = try Self.defaultOutputDeviceID()
        currentOutputDeviceID = outputDeviceID
        currentOutputDeviceName = (try? Self.deviceName(outputDeviceID)) ?? "Device \(outputDeviceID)"

        let outputDeviceUID = try Self.deviceUID(outputDeviceID)

        // DIAGNOSTIC: temporarily exclude nothing — tap *every* process including
        // our own. This is unsafe for routing (potential feedback) but it isolates
        // whether the PID-exclusion is what's causing the tap to deliver silence.
        // Keep the test tone OFF while this is empty.
        let ownProcessObjectID = (try? Self.processObjectIDForCurrentPID()) ?? 0
        excludedProcessObjectID.set(Int64(ownProcessObjectID))

        // Global tap, excluding our own process to prevent the
        // AVAudioEngine output → tap → output feedback loop.
        let tapDescription = CATapDescription(
            stereoGlobalTapButExcludeProcesses: [ownProcessObjectID]
        )
        tapDescription.name = "AuditumEQ-Tap"
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
        tapID = newTapID

        let aggUID = "com.shawnbrown.AuditumEQ.aggregate.\(UUID().uuidString)"
        let tapUIDString = try Self.tapUIDString(tapID)

        // Aggregate with the real output device as the main subdevice (for clock),
        // and the tap attached via the tap list. The IOProc reads the tap's audio
        // from the aggregate's input scope.
        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "AuditumEQ Aggregate",
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
                    kAudioSubTapUIDKey as String: tapUIDString,
                    kAudioSubTapDriftCompensationKey as String: 1
                ]
            ]
        ]

        var newAggID: AudioDeviceID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &newAggID)
        guard aggStatus == noErr, newAggID != kAudioObjectUnknown else {
            throw TapError.aggregateCreationFailed(aggStatus)
        }
        aggregateDeviceID = newAggID

        // Read the tap stream format off the aggregate's input scope.
        var asbd = try Self.inputStreamFormat(aggregateDeviceID)
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw TapError.formatUnsupported
        }
        tapFormat = format
        tapChannelCount = Int(format.channelCount)

        // ~250ms headroom per channel ring.
        let ringCapacity = max(4096, Int(format.sampleRate) / 4)
        let leftRing = TapRingBuffer(capacityFrames: ringCapacity)
        let rightRing = TapRingBuffer(capacityFrames: ringCapacity)
        self.leftRing = leftRing
        self.rightRing = rightRing

        // Source nodes emit stereo Float32 non-interleaved.
        let stereoFormat = AVAudioFormat(
            standardFormatWithSampleRate: format.sampleRate,
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
            preIngest.renderBlockEntries &+= 1
            if let callback = preIngest.callback {
                if let lPtr = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                    callback(lPtr, Int(frameCount), sourceSR)
                    preIngest.callbackInvocations &+= 1
                }
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

        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateDeviceID,
            nil
        ) { _, inInputData, _, _, _ in
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

    private func installDefaultOutputDeviceListener() {
        guard !deviceListenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor in
                await self?.handleDefaultOutputDeviceChanged()
            }
        }
        if status == noErr {
            deviceListenerInstalled = true
        } else {
            log.error("Failed to install default-output listener: \(status)")
        }
    }

    private func handleDefaultOutputDeviceChanged() async {
        guard let newID = try? Self.defaultOutputDeviceID(), newID != currentOutputDeviceID else { return }
        log.info("Default output device changed: \(self.currentOutputDeviceID) → \(newID)")
        tearDownTapAndAggregate()
        await start()
        onOutputDeviceChanged?(currentOutputDeviceID)
    }

    // MARK: - Teardown

    private func tearDown() {
        tearDownTapAndAggregate()
        if deviceListenerInstalled {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main
            ) { _, _ in }
            deviceListenerInstalled = false
        }
        leftSourceNode = nil
        rightSourceNode = nil
        tapFormat = nil
        sourceFormat = nil
        leftRing = nil
        rightRing = nil
    }

    private func tearDownTapAndAggregate() {
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

@available(macOS 14.2, *)
extension CATapEngine {

    static func defaultOutputDeviceID() throws -> AudioDeviceID {
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
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr else { throw TapError.deviceUIDUnavailable(status) }
        return name as String
    }

    nonisolated static func deviceUID(_ deviceID: AudioDeviceID) throws -> String {
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr else { throw TapError.deviceUIDUnavailable(status) }
        return uid as String
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

    static func tapUIDString(_ tapID: AudioObjectID) throws -> String {
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &uid)
        guard status == noErr else { throw TapError.tapUIDUnavailable(status) }
        return uid as String
    }

    static func inputStreamFormat(_ deviceID: AudioDeviceID) throws -> AudioStreamBasicDescription {
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
    static func processObjectIDForCurrentPID() throws -> AudioObjectID {
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
