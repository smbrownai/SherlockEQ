import Foundation
import OSLog
import Security

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
///
/// ## Authentication
///
/// A `CFMessagePortCreateLocal` port is registered in the per-user bootstrap
/// namespace, so only same-user processes in the session can reach it — but
/// CFMessagePort exposes no way to identify the sender (no PID, no audit
/// token), so the channel is *unauthenticated at the Mach layer*. To stop the
/// unsandboxed app from being driven as a confused deputy by an arbitrary
/// local process (e.g. to abuse `profiles.export`'s file write), we gate every
/// request on a **per-launch capability token**: a 32-byte random value the
/// app writes to a `0600` file only the user can read, which the CLI must echo
/// back. The check fails closed — no token, no service. This raises the bar to
/// "can read a file in the user's home"; a fully trusted same-user process can
/// still read the token, so this is defense-in-depth, not a privilege boundary.
/// True peer authentication would require migrating to XPC (`auditToken`).
final class CLIControlServer {

    /// Bootstrap name the CLI looks up. Derived from the bundle id so a
    /// renamed build can't collide with another app's port.
    static let portName = "com.shawnbrown.SherlockEQ.cli"

    /// Owner-only file the per-launch auth token is written to. The CLI reads
    /// it and echoes the value back on every request. Must match the path the
    /// CLI computes in `IPCClient.authTokenURL`.
    static var authTokenURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("SherlockEQ", isDirectory: true)
            .appendingPathComponent(".cli-auth-token", isDirectory: false)
    }

    /// Per-launch secret. `nil` until `start()` provisions it (and if
    /// provisioning fails, every request is rejected — fail closed).
    private var authToken: String?

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

        provisionAuthToken()

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
        // Drop the on-disk token so a later, unrelated process can't reuse it.
        try? FileManager.default.removeItem(at: Self.authTokenURL)
        authToken = nil
    }

    /// Generate a fresh per-launch token and write it owner-only. On any
    /// failure `authToken` stays nil, which makes every request unauthorized
    /// (the CLI surface goes dark rather than open).
    private func provisionAuthToken() {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            log.error("Could not generate CLI auth token — CLI commands will be rejected")
            authToken = nil
            return
        }
        let token = Data(bytes).base64EncodedString()
        let url = Self.authTokenURL
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            log.error("Could not create support directory for CLI token: \(error.localizedDescription, privacy: .public)")
        }
        // Replace any stale token from a previous launch, owner read/write only.
        try? fm.removeItem(at: url)
        if fm.createFile(atPath: url.path,
                         contents: Data(token.utf8),
                         attributes: [.posixPermissions: 0o600]) {
            authToken = token
        } else {
            log.error("Could not write CLI auth token file — CLI commands will be rejected")
            authToken = nil
        }
    }

    /// Validate the request's `token` field against this launch's secret.
    /// Returns false when no token was provisioned, the field is absent, or it
    /// doesn't match. The comparison is constant-time over equal-length input.
    private func isAuthorized(_ data: Data) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let request = object as? [String: Any],
            let provided = request["token"] as? String
        else { return false }
        return tokenMatches(provided)
    }

    private func tokenMatches(_ provided: String) -> Bool {
        guard let expected = authToken else { return false }
        let a = Array(expected.utf8)
        let b = Array(provided.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// Called by the C callback (on the main thread). Kept internal so the
    /// free function below can reach it. Rejects any request that doesn't
    /// carry the valid per-launch token before it reaches a command handler.
    fileprivate func respond(to data: Data) -> Data {
        guard isAuthorized(data) else {
            log.error("Rejected CLI request with missing or invalid auth token")
            return Self.unauthorizedReply
        }
        return handle(data)
    }

    private static let unauthorizedReply = Data(
        #"{"ok":false,"code":"unauthorized","error":"Request rejected: missing or invalid authentication token."}"#.utf8
    )
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
