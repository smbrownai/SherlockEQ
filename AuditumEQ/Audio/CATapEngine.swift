import Foundation
import AVFoundation
import Combine
import CoreAudio
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

    /// Mono source node for the left channel of the captured stream.
    /// Emits **stereo** with L = tapped L, R = 0 — so a downstream EQ can process
    /// it independently and the result re-mixes cleanly with the right chain.
    private(set) var leftSourceNode: AVAudioSourceNode?
    /// Mono source node for the right channel (stereo with L = 0, R = tapped R).
    private(set) var rightSourceNode: AVAudioSourceNode?

    /// Format both source nodes emit (stereo, tap sample rate).
    private(set) var sourceFormat: AVAudioFormat?
    /// Tap stream descriptor — sample rate, channel count of the raw tap.
    private(set) var tapFormat: AVAudioFormat?

    var onOutputDeviceChanged: ((AudioDeviceID) -> Void)?

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
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        permissionGranted = granted
        guard granted else {
            state = .permissionDenied
            log.error("Audio capture permission denied")
            return
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

        let outputDeviceUID = try Self.deviceUID(outputDeviceID)

        // Exclude our own process so AVAudioEngine's playback isn't recaptured.
        // Without this we'd build a feedback loop the moment we route audio to output.
        let ownProcessObjectID = try Self.processObjectIDForCurrentPID()
        let tapDescription = CATapDescription(
            stereoGlobalTapButExcludeProcesses: [NSNumber(value: ownProcessObjectID)]
        )
        tapDescription.muteBehavior = .muted   // silence the original path; we re-emit via AVAudioEngine
        tapDescription.name = "AuditumEQ-Tap"
        tapDescription.isPrivate = true

        var newTapID: AUAudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw TapError.tapCreationFailed(tapStatus)
        }
        tapID = newTapID

        let aggUID = "com.shawnbrown.AuditumEQ.aggregate.\(UUID().uuidString)"
        let tapUIDString = try Self.tapUIDString(tapID)

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

        leftSourceNode = AVAudioSourceNode(format: stereoFormat) { [weak leftRing] _, _, frameCount, audioBufferList -> OSStatus in
            Self.fillFromMonoRing(
                ring: leftRing,
                channelIndex: 0,
                abl: audioBufferList,
                frameCount: frameCount
            )
        }
        rightSourceNode = AVAudioSourceNode(format: stereoFormat) { [weak rightRing] _, _, frameCount, audioBufferList -> OSStatus in
            Self.fillFromMonoRing(
                ring: rightRing,
                channelIndex: 1,
                abl: audioBufferList,
                frameCount: frameCount
            )
        }
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
        let channelCount = tapChannelCount

        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateDeviceID,
            nil
        ) { _, inInputData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard let first = abl.first, let basePtr = first.mData else { return }
            let bytesPerFrame = MemoryLayout<Float>.size * channelCount
            let frames = Int(first.mDataByteSize) / max(1, bytesPerFrame)
            if frames <= 0 { return }

            // Tap formats from a stereoGlobalTap are interleaved stereo Float32.
            let src = basePtr.assumingMemoryBound(to: Float.self)
            leftRef.takeUnretainedValue().writeChannel(
                from: src, frameCount: frames, channelIndex: 0, channelCount: channelCount
            )
            rightRef.takeUnretainedValue().writeChannel(
                from: src,
                frameCount: frames,
                channelIndex: channelCount > 1 ? 1 : 0,
                channelCount: channelCount
            )
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

    static func deviceUID(_ deviceID: AudioDeviceID) throws -> String {
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
