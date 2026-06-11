import Foundation
import Combine
import CoreAudio

/// Enumerates the system's output devices and switches the **macOS default
/// output** — the same selection the menu-bar Sound control drives. Backs the
/// Analog Control Unit's OUTPUT selector: pressing a speaker button makes that
/// device the system default, and `CATapEngine` (which follows the default
/// output) rebuilds onto it automatically.
///
/// System-wide by design: this writes the real default-output device, so it
/// reroutes *all* audio, exactly like picking a device in the Sound menu — not
/// a SherlockEQ-private route. SherlockEQ taps whatever the system default is,
/// so this is the only honest way to "switch speakers" from the panel.
///
/// All CoreAudio I/O runs on a private serial queue; only the published
/// `devices` / `currentDeviceID` are mutated on the main thread. Keeping the
/// synchronous HAL reads off the main thread avoids the post-sleep/wake wedge
/// that can hang `AudioObjectGetPropertyData` (see
/// `coreaudio-sync-main-thread-hang`).
final class SystemOutputDeviceController: ObservableObject {
    /// Every device that can act as an output, refreshed on hardware changes.
    @Published private(set) var devices: [CATapEngine.OutputDevice] = []
    /// The current system default output device (the lit button).
    @Published private(set) var currentDeviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)

    private let queue = DispatchQueue(label: "com.shawnbrown.SherlockEQ.systemOutput")
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var defaultListener: AudioObjectPropertyListenerBlock?

    func start() { queue.async { self._start() } }
    func stop()  { queue.async { self._stop() } }

    /// Make `device` the system default output. Updates the UI optimistically
    /// for a responsive press; the default-device listener confirms the
    /// hardware value shortly after (and reverts the lamp if the set failed).
    func select(_ device: CATapEngine.OutputDevice) {
        publish(current: device.id)
        queue.async { self._setDefault(device.id) }
    }

    // MARK: - Queue-confined CoreAudio work

    private func _start() {
        _installListeners()
        _refresh()
    }

    private func _stop() { _removeListeners() }

    private func _refresh() {
        let devs = CATapEngine.allOutputDevices()
        let current = (try? CATapEngine.defaultOutputDeviceID()) ?? AudioDeviceID(kAudioObjectUnknown)
        DispatchQueue.main.async {
            self.devices = devs
            self.currentDeviceID = current
        }
    }

    private func _setDefault(_ id: AudioDeviceID) {
        guard id != AudioDeviceID(kAudioObjectUnknown) else { return }
        var addr = Self.defaultDeviceAddress()
        var device = id
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &device)
    }

    // MARK: - Listeners

    private func _installListeners() {
        var devAddr = Self.deviceListAddress()
        let devBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?._refresh() }
        deviceListListener = devBlock
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devAddr, queue, devBlock)

        var defAddr = Self.defaultDeviceAddress()
        let defBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?._refresh() }
        defaultListener = defBlock
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defAddr, queue, defBlock)
    }

    private func _removeListeners() {
        if let block = deviceListListener {
            var addr = Self.deviceListAddress()
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
            deviceListListener = nil
        }
        if let block = defaultListener {
            var addr = Self.defaultDeviceAddress()
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
            defaultListener = nil
        }
    }

    // MARK: - Helpers

    private func publish(current: AudioDeviceID) {
        DispatchQueue.main.async { self.currentDeviceID = current }
    }

    private static func defaultDeviceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceListAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }
}
