import AppKit
import Carbon.HIToolbox
import OSLog

/// System-wide keyboard shortcut wrapper around Carbon's `RegisterEventHotKey`.
/// Use this when an action needs to fire even when AuditumEQ is in the
/// background. The Carbon API is the only supported public route for global
/// hotkeys on macOS — `NSEvent.addGlobalMonitorForEvents` can observe keys
/// but does not consume them, so it can't replace it.
///
/// Only one hotkey per instance; create more instances if you need more.
@MainActor
final class GlobalHotKey {

    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32
    private let log = Logger(subsystem: "com.shawnbrown.AuditumEQ", category: "GlobalHotKey")

    init() {
        Self.idCounter += 1
        self.id = Self.idCounter
        Self.installEventHandlerIfNeeded()
    }

    deinit { Self.handlers[id] = nil; if let ref = hotKeyRef { UnregisterEventHotKey(ref) } }

    /// Register the hotkey. `keyCode` is a `kVK_*` constant from
    /// `Carbon.HIToolbox`. `modifiers` is the OR of `cmdKey`, `shiftKey`,
    /// `optionKey`, `controlKey`. Replaces any previously-registered shortcut
    /// on this instance.
    func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        unregister()
        Self.handlers[id] = handler
        let signature: OSType = 0x41454153  // 'AEAS' — AuditumEQ App Shortcut
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            log.error("RegisterEventHotKey failed: \(status)")
            Self.handlers[id] = nil
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        Self.handlers[id] = nil
    }

    // MARK: - Shared dispatcher
    //
    // Carbon delivers all hotkey events through one application event
    // handler. We register that once and route by hotkey id into the
    // per-instance closures.

    nonisolated(unsafe) private static var idCounter: UInt32 = 0
    nonisolated(unsafe) fileprivate static var handlers: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var handlerInstalled = false

    nonisolated private static func installEventHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return noErr }
                var hkID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if status == noErr {
                    let id = hkID.id
                    DispatchQueue.main.async {
                        GlobalHotKey.handlers[id]?()
                    }
                }
                return noErr
            },
            1,
            &spec,
            nil,
            nil
        )
    }
}
