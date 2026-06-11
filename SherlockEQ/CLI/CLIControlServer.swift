import Foundation
import OSLog

/// In-process control server for the `sherlockeq` command-line tool.
///
/// The CLI is a thin client: it never touches DSP, profile files, or
/// preferences directly. It connects to this server over a `CFMessagePort`
/// (a native, name-discoverable, request/reply Mach-backed channel — no
/// launchd registration, no sockets to manage), sends a JSON request, and
/// gets a JSON reply. The running app stays the single source of truth; this
/// server reads and mutates state only through the same `AudioState` /
/// `ProfileStore` APIs the GUI uses, so any change shows up in the GUI live.
///
/// The port is local to this app instance. `CFMessagePortCreateRemote(name)`
/// on the CLI side returns nil when the app isn't running, which the CLI maps
/// to a clean "not running" error and exit code — see `CLICommandHandler` for
/// the verbs and the matching client in `cli/`.
final class CLIControlServer {

    /// Bootstrap name the CLI looks up. Derived from the bundle id so a
    /// renamed build can't collide with another app's port.
    static let portName = "com.shawnbrown.SherlockEQ.cli"

    /// Synchronous request handler, invoked on the main run loop (see below),
    /// so it is free to touch `@MainActor` state via `MainActor.assumeIsolated`.
    private let handle: (Data) -> Data

    private var port: CFMessagePort?
    private var source: CFRunLoopSource?
    private let log = Logger(subsystem: "com.shawnbrown.SherlockEQ", category: "CLIControlServer")

    init(handle: @escaping (Data) -> Data) {
        self.handle = handle
    }

    /// Vend the port and schedule it on the **main** run loop. Scheduling on
    /// the main loop is deliberate: the callback then fires on the main thread,
    /// where the handler can safely reach `@MainActor` app state.
    func start() {
        guard port == nil else { return }

        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let port = CFMessagePortCreateLocal(
            nil,
            Self.portName as CFString,
            cliControlServerCallback,
            &context,
            nil
        ) else {
            // Name already registered — almost certainly another SherlockEQ
            // instance (the multi-instance guard in AppDelegate should have
            // prevented that). Log and run without the CLI surface rather
            // than crashing the app over an optional feature.
            log.error("Could not create CLI control port — CLI commands will be unavailable")
            return
        }
        self.port = port

        guard let source = CFMessagePortCreateRunLoopSource(nil, port, 0) else {
            log.error("Could not create CLI control run-loop source")
            CFMessagePortInvalidate(port)
            self.port = nil
            return
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        log.info("CLI control port listening as \(Self.portName, privacy: .public)")
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = nil
        }
        if let port {
            CFMessagePortInvalidate(port)
            self.port = nil
        }
    }

    /// Called by the C callback (on the main thread). Kept internal so the
    /// free function below can reach it.
    fileprivate func respond(to data: Data) -> Data {
        handle(data)
    }
}

/// C-compatible callback (no captured context — the server is reached via the
/// `info` pointer stored in the port context). Runs on whatever loop the port
/// is scheduled on; we scheduled the main loop, so this is the main thread.
private func cliControlServerCallback(
    _ local: CFMessagePort?,
    _ msgid: Int32,
    _ data: CFData?,
    _ info: UnsafeMutableRawPointer?
) -> Unmanaged<CFData>? {
    guard let info else { return nil }
    let server = Unmanaged<CLIControlServer>.fromOpaque(info).takeUnretainedValue()
    let request = (data as Data?) ?? Data()
    let reply = server.respond(to: request)
    // CFMessagePort releases the returned data after sending it, so hand it a
    // +1 reference.
    return Unmanaged.passRetained(reply as CFData)
}
