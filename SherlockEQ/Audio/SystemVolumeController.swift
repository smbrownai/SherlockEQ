import Foundation
import Combine
import CoreAudio
import AudioToolbox

/// Reads and writes the **macOS system output volume** — the same level the
/// menu-bar slider and the volume keys drive — for the current default
/// output device.
///
/// Two consumers, deliberately with separate instances:
///   • The Analog Control Unit's VOLUME knob (window-lifecycle instance,
///     started on appear / stopped on disappear).
///   • `AudioState` (always-on instance) — anchors the Safe-Listening SPL
///     calibration to the hardware volume it was measured at, so the dose
///     estimate tracks the volume keys instead of assuming a fixed output
///     level. See `volume-aware-dose.md` and `CalibrationVolumeAnchor`.
///
/// Deliberately separate from SherlockEQ's DSP: it does NOT touch the audio
/// engine or the limiter — the hardware volume sits downstream of the
/// entire signal path (and of the CATap capture point, which is why the
/// dose math needs this readout at all).
///
/// All CoreAudio I/O runs on a private serial queue; only the published
/// properties are mutated on the main thread. Keeping the synchronous HAL
/// reads off the main thread avoids the post-sleep/wake wedge that can hang
/// `AudioObjectGetPropertyData` (see `coreaudio-sync-main-thread-hang`).
final class SystemVolumeController: ObservableObject {
    /// Current system output volume, 0…1. Mirrors the menu-bar slider.
    @Published private(set) var volume: Double = 0
    /// True when the current output device exposes a settable main volume.
    /// HDMI / optical / some aggregate devices don't — the knob disables.
    @Published private(set) var isAvailable: Bool = false
    /// Current output volume in dB (attenuation relative to the device's
    /// full-scale output). `nil` when the device exposes no readable volume.
    /// Read via the device's own scalar→dB curve where available; the
    /// consumers only ever use *differences* between two readings on the
    /// same device, so any monotone, device-consistent mapping is exact for
    /// that purpose (see `volume-aware-dose.md` §3).
    @Published private(set) var volumeDB: Double?
    /// True when the output device is muted (`kAudioDevicePropertyMute`).
    /// False when the device doesn't expose a mute control.
    @Published private(set) var isMuted: Bool = false
    /// UID of the bound default output device — the identity the calibration
    /// anchor is checked against after route changes. `nil` until the first
    /// read completes.
    @Published private(set) var deviceUID: String?

    private let queue = DispatchQueue(label: "com.shawnbrown.SherlockEQ.systemVolume")
    private var deviceID = AudioObjectID(kAudioObjectUnknown)        // queue-confined
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var muteListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    // 'vmvc' — the virtual main (master) volume, the menu-bar slider's value.
    nonisolated private static let mainVolumeSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume

    func start() { queue.async { self._start() } }
    func stop()  { queue.async { self._stop() } }

    /// Set the system volume. Updates the UI optimistically for a responsive
    /// knob; the property listener confirms the hardware value shortly after.
    func setVolume(_ newValue: Double) {
        let clamped = min(1, max(0, newValue))
        publish(volume: clamped, available: isAvailable,
                volumeDB: volumeDB, muted: isMuted, uid: deviceUID)
        queue.async { self._setVolume(clamped) }
    }

    // MARK: - Queue-confined CoreAudio work

    private func _start() {
        _installDefaultDeviceListener()
        _retarget()
    }

    private func _stop() {
        _removeDeviceListeners()
        _removeDefaultDeviceListener()
    }

    /// (Re)bind to the current default output device and refresh.
    private func _retarget() {
        _removeDeviceListeners()
        deviceID = Self.defaultOutputDevice()
        _refresh()
        _installDeviceListeners()
    }

    /// Read the full state and publish it. Called on retarget and from the
    /// volume/mute property listeners.
    private func _refresh() {
        let s = _readState()
        publish(volume: s.volume, available: s.available,
                volumeDB: s.volumeDB, muted: s.muted, uid: s.uid)
    }

    private func _readState() -> (available: Bool, volume: Double,
                                  volumeDB: Double?, muted: Bool, uid: String?) {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return (false, 0, nil, false, nil)
        }
        let uid = _readDeviceUID()
        let muted = _readMuted()
        var addr = Self.volumeAddress()
        guard AudioObjectHasProperty(deviceID, &addr) else {
            return (false, 0, nil, muted, uid)
        }
        var settable: DarwinBoolean = false
        AudioObjectIsPropertySettable(deviceID, &addr, &settable)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value)
        guard status == noErr else { return (false, 0, nil, muted, uid) }
        let vol = Double(value)
        return (settable.boolValue, vol, _readVolumeDB(scalar: vol), muted, uid)
    }

    /// Current output volume in dB. Strategy (first hit wins — what matters
    /// is per-device consistency, not absolute accuracy):
    ///   1. `kAudioDevicePropertyVolumeScalarToDecibels` translation of the
    ///      current scalar — the device's own taper, exact.
    ///   2. `kAudioDevicePropertyVolumeDecibels` direct read.
    ///   3. `20·log10(scalar)` floor-clamped — approximate taper, but
    ///      monotone and consistent per device.
    /// Elements: main first, then channel 1 (some devices only publish
    /// per-channel volume elements).
    private func _readVolumeDB(scalar: Double) -> Double? {
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1]
        for element in elements {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalarToDecibels,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            guard AudioObjectHasProperty(deviceID, &addr) else { continue }
            var value = Float32(scalar)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value) == noErr,
               value.isFinite {
                return Double(value)
            }
        }
        for element in elements {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeDecibels,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            guard AudioObjectHasProperty(deviceID, &addr) else { continue }
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value) == noErr,
               value.isFinite {
                return Double(value)
            }
        }
        // Fallback: log of the scalar. Floor at −80 dB so a zeroed slider
        // stays finite (the anchor math clamps to the same floor).
        guard scalar > 0 else { return -80 }
        return max(20 * log10(scalar), -80)
    }

    private func _readMuted() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(deviceID, &addr) else { return false }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    private func _readDeviceUID() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &uid)
        guard status == noErr, let cf = uid?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private func _setVolume(_ v: Double) {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        var addr = Self.volumeAddress()
        guard AudioObjectHasProperty(deviceID, &addr) else { return }
        var value = Float32(min(1, max(0, v)))
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    private func _installDeviceListeners() {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?._refresh()
        }
        var volAddr = Self.volumeAddress()
        volumeListener = block
        AudioObjectAddPropertyListenerBlock(deviceID, &volAddr, queue, block)

        var muteAddr = Self.muteAddress()
        if AudioObjectHasProperty(deviceID, &muteAddr) {
            muteListener = block
            AudioObjectAddPropertyListenerBlock(deviceID, &muteAddr, queue, block)
        }
    }

    private func _removeDeviceListeners() {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else {
            volumeListener = nil
            muteListener = nil
            return
        }
        if let block = volumeListener {
            var addr = Self.volumeAddress()
            AudioObjectRemovePropertyListenerBlock(deviceID, &addr, queue, block)
        }
        if let block = muteListener {
            var addr = Self.muteAddress()
            AudioObjectRemovePropertyListenerBlock(deviceID, &addr, queue, block)
        }
        volumeListener = nil
        muteListener = nil
    }

    private func _installDefaultDeviceListener() {
        var addr = Self.defaultDeviceAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?._retarget()
        }
        defaultDeviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
    }

    private func _removeDefaultDeviceListener() {
        guard let block = defaultDeviceListener else { return }
        var addr = Self.defaultDeviceAddress()
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        defaultDeviceListener = nil
    }

    // MARK: - Helpers

    private func publish(volume: Double, available: Bool,
                         volumeDB: Double?, muted: Bool, uid: String?) {
        DispatchQueue.main.async {
            self.volume = volume
            self.isAvailable = available
            self.volumeDB = volumeDB
            self.isMuted = muted
            self.deviceUID = uid
        }
    }

    nonisolated private static func defaultOutputDevice() -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = defaultDeviceAddress()
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    nonisolated private static func defaultDeviceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    nonisolated private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: mainVolumeSelector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    nonisolated private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: - Stateless device helpers (crash-mute recovery)
    //
    // Free functions that read/write a specific device without needing a live
    // controller instance — used by `TapMuteSentinel` recovery at launch and
    // by the tap-start mute snapshot. All synchronous CoreAudio calls; callers
    // must run them OFF the main thread (a wedged HAL can block indefinitely —
    // see memory `coreaudio-sync-main-thread-hang`).

    /// Mute flag of a specific device, or nil if it has no mute property.
    nonisolated static func muted(deviceID: AudioObjectID) -> Bool? {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        var addr = muteAddress()
        guard AudioObjectHasProperty(deviceID, &addr) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value != 0
    }

    /// Set a specific device's mute flag. Returns true on success.
    @discardableResult
    nonisolated static func setMuted(_ muted: Bool, deviceID: AudioObjectID) -> Bool {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return false }
        var addr = muteAddress()
        guard AudioObjectHasProperty(deviceID, &addr) else { return false }
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(
            deviceID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        return status == noErr
    }

    /// UID of the current default output device, or nil if unavailable.
    nonisolated static func defaultOutputDeviceUID() -> String? {
        let dev = defaultOutputDevice()
        guard dev != AudioObjectID(kAudioObjectUnknown) else { return nil }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr,
              let cf = uid?.takeRetainedValue() else { return nil }
        return cf as String
    }

    /// Mute flag of the current default output device.
    nonisolated static func defaultOutputMuted() -> Bool? {
        muted(deviceID: defaultOutputDevice())
    }

    /// Set the current default output device's mute flag.
    @discardableResult
    nonisolated static func setDefaultOutputMuted(_ muted: Bool) -> Bool {
        setMuted(muted, deviceID: defaultOutputDevice())
    }
}
