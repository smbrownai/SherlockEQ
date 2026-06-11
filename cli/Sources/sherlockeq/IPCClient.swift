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

        var description: String {
            switch self {
            case .notRunning:        return "SherlockEQ is not running."
            case .sendFailed(let s): return "message send failed (status \(s))"
            case .emptyReply:        return "no reply from SherlockEQ"
            case .badReply:          return "unreadable reply from SherlockEQ"
            }
        }
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

        let payload = try JSONSerialization.data(withJSONObject: request)
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
