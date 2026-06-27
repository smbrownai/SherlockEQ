import ArgumentParser
import Foundation

/// CLI version. Kept in step with the app's marketing version by
/// dist/build-cli.sh (which rewrites this line at build time).
let cliVersion = "0.6.8"

// MARK: - Root

@main
struct SherlockeqTool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sherlockeq",
        abstract: "Control the running SherlockEQ app from the command line.",
        discussion: """
            A power-user and automation surface for SherlockEQ — not a \
            replacement for the app. The running app is the source of truth; \
            these commands ask it to report or change state, so the GUI stays \
            in sync. Add --json to most commands for machine-readable output. \
            All operation is local: no telemetry, no network.
            """,
        version: cliVersion,
        subcommands: [
            Status.self,
            Diagnostics.self,
            Launch.self,
            Quit.self,
            Bypass.self,
            Profiles.self,
            Devices.self,
            Gain.self,
            Balance.self,
            SimpleEQ.self,
            Reset.self,
            Install.self,
            Uninstall.self,
        ]
    )
}

// MARK: - Shared options

struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Emit machine-readable JSON instead of text.")
    var json = false
}

// MARK: - Exit codes

enum ExitStatus: Int32 {
    case ok = 0
    case generic = 1
    // 2 is reserved by ArgumentParser for usage errors.
    case notRunning = 3
    case notFound = 4
    case invalid = 5
}

func die(_ message: String, _ status: ExitStatus = .generic) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(status.rawValue)
}

/// Map a server-side error `code` to a process exit status.
func exitStatus(forServerCode code: String) -> ExitStatus {
    switch code {
    case "not_found", "ambiguous", "no_active_profile": return .notFound
    case "invalid_argument", "out_of_range", "bad_request": return .invalid
    default: return .generic
    }
}

// MARK: - Request helper

/// Send a command and return its `data` payload, or exit with a clear message
/// and the right code. Used by every command that must reach a running app.
@discardableResult
func sendCommand(_ request: [String: Any]) -> [String: Any] {
    let reply: [String: Any]
    do {
        reply = try IPCClient.send(request)
    } catch IPCClient.ClientError.notRunning {
        die("SherlockEQ isn't running. Start it with `sherlockeq launch`, or open the app.", .notRunning)
    } catch {
        die("Couldn't reach SherlockEQ: \(error).", .notRunning)
    }
    if (reply["ok"] as? Bool) == true {
        return reply["data"] as? [String: Any] ?? [:]
    }
    let code = reply["code"] as? String ?? "error"
    let message = reply["error"] as? String ?? "Command failed."
    die(message, exitStatus(forServerCode: code))
}

// MARK: - Output helpers

/// Print a payload as pretty JSON, or run a human formatter — the `--json`
/// branch every command shares.
func emit(_ data: [String: Any], json: Bool, human: @autoclosure () -> String) {
    if json { emitJSON(data) } else { print(human()) }
}

func emitJSON(_ object: Any) {
    guard
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
        let string = String(data: data, encoding: .utf8)
    else {
        die("Could not encode JSON output.")
    }
    print(string)
}

// MARK: - Formatting

func formatDB(_ value: Any?) -> String {
    guard let n = asDouble(value) else { return "—" }
    if abs(n) < 0.05 { return "0.0 dB" }
    return String(format: "%@%.1f dB", n > 0 ? "+" : "−", abs(n))
}

func formatBalance(_ value: Any?) -> String {
    guard let b = asDouble(value) else { return "—" }
    if abs(b) < 0.005 { return "center" }
    let pct = Int((abs(b) * 100).rounded())
    return b < 0 ? "L \(pct)%" : "R \(pct)%"
}

func asDouble(_ value: Any?) -> Double? {
    if let d = value as? Double { return d }
    if let i = value as? Int { return Double(i) }
    if let n = value as? NSNumber { return n.doubleValue }
    return nil
}

/// Resolve a possibly-relative, possibly-tilde path against the CLI's CWD so
/// the app (a different process, different working directory) reads/writes the
/// file the user meant.
func absolutePath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return (expanded as NSString).standardizingPath
    }
    let cwd = FileManager.default.currentDirectoryPath
    return ((cwd as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
}
