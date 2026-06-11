import Foundation
import Combine
import CoreAudio
import AudioToolbox

/// Reads and writes the **macOS system output volume** — the same level the
/// menu-bar slider and the volume keys drive — for the current default
/// output device. Used only by the Analog Control Unit's VOLUME knob, the
/// one control that deliberately reaches outside SherlockEQ's own signal
/// path (the rest map to the app's gain / balance / EQ).
///
/// Deliberately separate from SherlockEQ's DSP: it does NOT touch the audio
/// engine, the limiter, or the Safe-Listening SPL calibration (which still
/// assumes a fixed system output level — moving this knob changes the
/// hardware level downstream of all of that).
///
/// All CoreAudio I/O runs on a private serial queue; only the published
/// `volume` / `isAvailable` are mutated on the main thread. Keeping the
/// synchronous HAL reads off the main thread avoids the post-sleep/wake
/// wedge that can hang `AudioObjectGetPropertyData` (see
/// `coreaudio-sync-main-thread-hang`).
final class SystemVolumeController: ObservableObject {
    /// Current system output volume, 0…1. Mirrors the menu-bar slider.
    @Published private(set) var volume: Double = 0
    /// True when the current output device exposes a settable main volume.
    /// HDMI / optical / some aggregate devices don't — the knob disables.
    @Published private(set) var isAvailable: Bool = false

    private let queue = DispatchQueue(label: "com.shawnbrown.SherlockEQ.systemVolume")
    private var deviceID = AudioObjectID(kAudioObjectUnknown)        // queue-confined
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    // 'vmvc' — the virtual main (master) volume, the menu-bar slider's value.
    private static let mainVolumeSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume

    func start() { queue.async { self._start() } }
    func stop()  { queue.async { self._stop() } }

    /// Set the system volume. Updates the UI optimistically for a responsive
    /// knob; the property listener confirms the hardware value shortly after.
    func setVolume(_ newValue: Double) {
        let clamped = min(1, max(0, newValue))
        publish(volume: clamped, available: isAvailable)
        queue.async { self._setVolume(clamped) }
    }

    // MARK: - Queue-confined CoreAudio work

    private func _start() {
        _installDefaultDeviceListener()
        _retarget()
    }

    private func _stop() {
        _removeVolumeListener()
        _removeDefaultDeviceListener()
    }

    /// (Re)bind to the current default output device and refresh.
    private func _retarget() {
        _removeVolumeListener()
        deviceID = Self.defaultOutputDevice()
        let (available, vol) = _readState()
        publish(volume: vol, available: available)
        _installVolumeListener()
    }

    private func _readState() -> (available: Bool, volume: Double) {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return (false, 0) }
        var addr = Self.volumeAddress()
        guard AudioObjectHasProperty(deviceID, &addr) else { return (false, 0) }
        var settable: DarwinBoolean = false
        AudioObjectIsPropertySettable(deviceID, &addr, &settable)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value)
        let vol = status == noErr ? Double(value) : 0
        return (settable.boolValue, vol)
    }

    private func _setVolume(_ v: Double) {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        var addr = Self.volumeAddress()
        guard AudioObjectHasProperty(deviceID, &addr) else { return }
        var value = Float32(min(1, max(0, v)))
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    private func _installVolumeListener() {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        var addr = Self.volumeAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let (available, vol) = self._readState()
            self.publish(volume: vol, available: available)
        }
        volumeListener = block
        AudioObjectAddPropertyListenerBlock(deviceID, &addr, queue, block)
    }

    private func _removeVolumeListener() {
        guard let block = volumeListener, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            volumeListener = nil
            return
        }
        var addr = Self.volumeAddress()
        AudioObjectRemovePropertyListenerBlock(deviceID, &addr, queue, block)
        volumeListener = nil
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

    private func publish(volume: Double, available: Bool) {
        DispatchQueue.main.async {
            self.volume = volume
            self.isAvailable = available
        }
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = defaultDeviceAddress()
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    private static func defaultDeviceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: mainVolumeSelector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }
}
