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

    /// The source node downstream consumers (AVAudioEngine) attach to.
    /// nil until the tap is running. Format matches the tap stream format.
    private(set) var sourceNode: AVAudioSourceNode?
    private(set) var tapFormat: AVAudioFormat?

    /// Fires after the default output device changes and the tap has been rebuilt.
    /// Consumers (AuditumEQAudioEngine, profile auto-switcher) listen and react.
    var onOutputDeviceChanged: ((AudioDeviceID) -> Void)?

    private let log = Logger(subsystem: "org.smbrown.AuditumEQ", category: "CATapEngine")

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    /// Lock-free ring buffer fed by the Core Audio IOProc and drained by the source node.
    private var ringBuffer: TapRingBuffer?

    private var deviceListenerInstalled = false

    deinit {
        // Synchronous teardown; safe to run off-main during deallocation.
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

        // Tap targets all processes (empty processes array + mono mixdown).
        // Excluding nothing — everything routed to the output device is captured.
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [])
        tapDescription.muteBehavior = .unmuted
        tapDescription.name = "AuditumEQ-Tap"
        tapDescription.isPrivate = true

        var newTapID: AUAudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw TapError.tapCreationFailed(tapStatus)
        }
        tapID = newTapID

        // Build a private aggregate device that owns this tap as a subdevice.
        // Aggregating with the current output keeps the tap clocked to that device.
        let aggUID = "org.smbrown.AuditumEQ.aggregate.\(UUID().uuidString)"
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

        // Read the input stream format from the aggregate device (the tap shows up
        // on its input scope). This is the format the source node will produce.
        var asbd = try Self.inputStreamFormat(aggregateDeviceID)
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw TapError.formatUnsupported
        }
        tapFormat = format

        let buffer = TapRingBuffer(
            channelCount: Int(format.channelCount),
            capacityFrames: max(4096, Int(format.sampleRate) / 4) // ~250ms headroom
        )
        ringBuffer = buffer

        sourceNode = AVAudioSourceNode(format: format) { [weak buffer] _, _, frameCount, audioBufferList -> OSStatus in
            // Realtime thread — no allocations, no Swift runtime allocations.
            guard let buffer else {
                return Self.fillSilence(audioBufferList, frameCount: frameCount)
            }
            let filled = buffer.read(into: audioBufferList, frameCount: Int(frameCount))
            if filled < Int(frameCount) {
                Self.fillSilence(audioBufferList, frameCount: frameCount, startingAtFrame: filled)
            }
            return noErr
        }
    }

    // MARK: - IO

    private func startIO() throws {
        guard let buffer = ringBuffer else { throw TapError.notConfigured }
        var procID: AudioDeviceIOProcID?
        let bufferRef = Unmanaged.passUnretained(buffer)

        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateDeviceID,
            nil
        ) { _, inInputData, _, _, _ in
            // Realtime IOProc — copy interleaved/non-interleaved input into the ring.
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            bufferRef.takeUnretainedValue().write(from: abl)
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
            // We installed with a block — the matching remove API takes the same address;
            // identity is implicit per listener block. macOS releases on object destruction
            // if we miss it, but call it for cleanliness.
            _ = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main
            ) { _, _ in }
            deviceListenerInstalled = false
        }
        sourceNode = nil
        tapFormat = nil
        ringBuffer = nil
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
        case notConfigured

        var description: String {
            switch self {
            case .tapCreationFailed(let s): return "AudioHardwareCreateProcessTap failed (\(s))"
            case .aggregateCreationFailed(let s): return "AudioHardwareCreateAggregateDevice failed (\(s))"
            case .ioProcCreationFailed(let s): return "AudioDeviceCreateIOProcIDWithBlock failed (\(s))"
            case .ioProcStartFailed(let s): return "AudioDeviceStart failed (\(s))"
            case .defaultOutputUnavailable(let s): return "Default output device query failed (\(s))"
            case .deviceUIDUnavailable(let s): return "Device UID query failed (\(s))"
            case .tapUIDUnavailable(let s): return "Tap UID query failed (\(s))"
            case .formatUnavailable(let s): return "Stream format query failed (\(s))"
            case .formatUnsupported: return "Stream format could not be expressed as AVAudioFormat"
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

    @discardableResult
    static func fillSilence(
        _ abl: UnsafeMutablePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount,
        startingAtFrame startFrame: Int = 0
    ) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let bytesPerFrame = Int(buffer.mDataByteSize) / max(1, Int(frameCount))
            let offset = startFrame * bytesPerFrame
            let length = max(0, Int(buffer.mDataByteSize) - offset)
            if length > 0 {
                memset(data.advanced(by: offset), 0, length)
            }
        }
        return noErr
    }
}

