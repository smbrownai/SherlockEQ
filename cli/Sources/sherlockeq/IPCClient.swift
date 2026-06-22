import CoreFoundation
import Foundation

/// Bundle identifier of the SherlockEQ app — used to launch it (`open -b`).
let sherlockEQBundleID = "com.shawnbrown.SherlockEQ"

/// Talks to the running app over the `CFMessagePort` it vends (see the app's
/// `CLIControlServer`). One request → one JSON reply. The CLI owns no app
/// state; this is the only channel.
enum IPCClient {
    /// Must match `CLIControlServer.portName` in the app.
    static let portName = "com.shawnbrown.SherlockEQ.cli"

    enum ClientError: Error, CustomStringConvertible {
        case notRunning
        case sendFailed(Int32)
        case emptyReply
        case badReply
        case noToken

        var description: String {
            switch self {
            case .notRunning:        return "SherlockEQ is not running."
            case .sendFailed(let s): return "message send failed (status \(s))"
            case .emptyReply:        return "no reply from SherlockEQ"
            case .badReply:          return "unreadable reply from SherlockEQ"
            case .noToken:           return "could not read the SherlockEQ control token — is the app running and owned by you?"
            }
        }
    }

    /// Owner-only file the app writes its per-launch control token to. Must
    /// match `CLIControlServer.authTokenURL`. The CLI echoes this value back on
    /// every request so the app can reject messages from other processes.
    private static var authTokenURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: false))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("SherlockEQ", isDirectory: true)
            .appendingPathComponent(".cli-auth-token", isDirectory: false)
    }

    private static func authToken() -> String? {
        guard
            let data = try? Data(contentsOf: authTokenURL),
            let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else { return nil }
        return token
    }

    /// True when the app's control port is registered (i.e. the app is up).
    static func isReachable() -> Bool {
        guard let remote = CFMessagePortCreateRemote(nil, portName as CFString) else { return false }
        CFMessagePortInvalidate(remote)
        return true
    }

    /// Send a JSON request object and return the decoded JSON reply object.
    /// `CFMessagePortSendRequest` spins the run loop in `replyMode` while it
    /// waits, so this works in a plain CLI with no run loop of its own.
    static func send(_ request: [String: Any], timeout: TimeInterval = 5) throws -> [String: Any] {
        guard let remote = CFMessagePortCreateRemote(nil, portName as CFString) else {
            throw ClientError.notRunning
        }
        defer { CFMessagePortInvalidate(remote) }

        // Authenticate every request with the app's per-launch token. The app
        // rejects messages without it, so a missing token file means we can't
        // talk to the app at all (it's either not running or not ours).
        guard let token = authToken() else { throw ClientError.noToken }
        var authedRequest = request
        authedRequest["token"] = token

        let payload = try JSONSerialization.data(withJSONObject: authedRequest)
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(
            remote,
            0,
            payload as CFData,
            timeout,
            timeout,
            CFRunLoopMode.defaultMode.rawValue,
            &reply
        )
        guard status == Int32(kCFMessagePortSuccess) else {
            throw ClientError.sendFailed(status)
        }
        guard let data = reply?.takeRetainedValue() as Data? else {
            throw ClientError.emptyReply
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any]
        else {
            throw ClientError.badReply
        }
        return dict
    }
}
