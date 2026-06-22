import ArgumentParser
import Foundation

// MARK: - status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report whether SherlockEQ is running, plus profile, device, bypass, gain, balance, and simple EQ."
    )
    @OptionGroup var global: GlobalOptions

    func run() {
        // Status answers a question; not-running is a valid answer, not a
        // failure — so it exits 0 either way (criterion 8).
        guard
            let reply = try? IPCClient.send(["command": "status"]),
            (reply["ok"] as? Bool) == true,
            let data = reply["data"] as? [String: Any]
        else {
            if global.json { emitJSON(["running": false]) }
            else { print("SherlockEQ   not running") }
            return
        }
        if global.json { emitJSON(data); return }

        var lines: [String] = []
        lines.append(label("SherlockEQ", "running"))
        let processing = (data["processing"] as? Bool) == true
        let tapState = data["tapState"] as? String ?? "?"
        lines.append(label("Processing", processing ? "yes" : "no (\(tapState))"))
        if let p = data["profile"] as? [String: Any], let name = p["name"] as? String {
            let builtIn = (p["builtIn"] as? Bool) == true
            lines.append(label("Profile", name + (builtIn ? " (built-in)" : "")))
        } else {
            lines.append(label("Profile", "none"))
        }
        if let d = data["outputDevice"] as? [String: Any], let name = d["name"] as? String {
            lines.append(label("Output", name))
        }
        lines.append(label("Bypass", (data["bypass"] as? Bool) == true ? "on" : "off"))
        lines.append(label("Gain", formatDB(data["gainDB"])))
        if data["balance"] != nil { lines.append(label("Balance", formatBalance(data["balance"]))) }
        if let eq = data["simpleEQ"] as? [String: Any] {
            lines.append(label("Simple EQ", "bass \(formatDB(eq["bass"]))   mid \(formatDB(eq["mid"]))   treble \(formatDB(eq["treble"]))"))
        }
        print(lines.joined(separator: "\n"))
    }

    private func label(_ key: String, _ value: String) -> String {
        let padded = key.padding(toLength: 12, withPad: " ", startingAt: 0)
        return "\(padded)\(value)"
    }
}

// MARK: - diagnostics

struct Diagnostics: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print a structured diagnostic snapshot suitable for bug reports."
    )
    @OptionGroup var global: GlobalOptions

    func run() {
        // Inherently structured — always JSON (so `diagnostics` and
        // `diagnostics --json` behave the same).
        let data = sendCommand(["command": "diagnostics"])
        emitJSON(data)
    }
}

// MARK: - launch / quit

struct Launch: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Launch SherlockEQ if it isn't already running.")
    @OptionGroup var global: GlobalOptions

    func run() {
        if IPCClient.isReachable() {
            emit(["launched": false, "alreadyRunning": true], json: global.json, human: "SherlockEQ is already running.")
            return
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-b", sherlockEQBundleID]
        do {
            try open.run()
            open.waitUntilExit()
        } catch {
            die("Could not launch SherlockEQ: \(error.localizedDescription)")
        }
        guard open.terminationStatus == 0 else {
            die("SherlockEQ doesn't appear to be installed (open -b \(sherlockEQBundleID) failed).", .notFound)
        }
        // Wait for the control port so a follow-up command works immediately.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if IPCClient.isReachable() {
                emit(["launched": true, "ready": true], json: global.json, human: "SherlockEQ launched.")
                return
            }
            usleep(200_000)
        }
        emit(["launched": true, "ready": false], json: global.json,
             human: "SherlockEQ is launching (not yet reachable).")
    }
}

struct Quit: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Quit the running SherlockEQ app.")
    @OptionGroup var global: GlobalOptions

    func run() {
        guard IPCClient.isReachable() else {
            emit(["quitting": false, "alreadyStopped": true], json: global.json, human: "SherlockEQ is not running.")
            return
        }
        let data = sendCommand(["command": "quit"])
        emit(data, json: global.json, human: "SherlockEQ is quitting.")
    }
}

// MARK: - bypass

struct Bypass: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Turn Reference Mode (bypass) on, off, or toggle it.")

    enum Mode: String, ExpressibleByArgument { case on, off, toggle }

    @Argument(help: "on | off | toggle")
    var mode: Mode
    @OptionGroup var global: GlobalOptions

    func run() {
        let data = sendCommand(["command": "bypass.set", "mode": mode.rawValue])
        let on = (data["bypass"] as? Bool) == true
        emit(data, json: global.json, human: "Bypass \(on ? "on" : "off")")
    }
}

// MARK: - gain

struct Gain: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Get or set master output gain (dB).",
        subcommands: [GainGet.self, GainSet.self]
    )
}

struct GainGet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Print master gain in dB.")
    @OptionGroup var global: GlobalOptions
    func run() {
        let data = sendCommand(["command": "gain.get"])
        emit(data, json: global.json, human: "Gain \(formatDB(data["gainDB"]))")
    }
}

struct GainSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set master gain in dB (-60…+12).")
    // `.allUnrecognized` into a one-element array so a bare negative like
    // `gain set -6` is taken as a value — a single-value positional rejects
    // leading-dash tokens. (`--json` isn't offered here; use `gain get --json`.)
    @Argument(parsing: .allUnrecognized, help: "Gain in dB, from -60 to +12 (e.g. -6).")
    var db: [Double] = []
    func run() {
        guard db.count == 1 else {
            die("Provide exactly one gain value, e.g. `sherlockeq gain set -6`.", .invalid)
        }
        let data = sendCommand(["command": "gain.set", "db": db[0]])
        print("Gain \(formatDB(data["gainDB"]))")
    }
}

// MARK: - balance

struct Balance: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Get or set stereo balance on the active profile.",
        subcommands: [BalanceGet.self, BalanceSet.self]
    )
}

struct BalanceGet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Print stereo balance.")
    @OptionGroup var global: GlobalOptions
    func run() {
        let data = sendCommand(["command": "balance.get"])
        emit(data, json: global.json, human: "Balance \(formatBalance(data["balance"]))")
    }
}

struct BalanceSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set stereo balance (-1 left … 0 center … 1 right).")
    // See GainSet: `.unconditional` array so `balance set -0.3` works.
    @Argument(parsing: .allUnrecognized, help: "Balance from -1 (full left) to 1 (full right), e.g. -0.3.")
    var value: [Double] = []
    func run() {
        guard value.count == 1 else {
            die("Provide exactly one balance value, e.g. `sherlockeq balance set -0.3`.", .invalid)
        }
        let data = sendCommand(["command": "balance.set", "value": value[0]])
        print("Balance \(formatBalance(data["balance"]))")
    }
}

// MARK: - simple-eq

struct SimpleEQ: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simple-eq",
        abstract: "Get or set the active profile's bass / mid / treble.",
        subcommands: [SimpleEQGet.self, SimpleEQSet.self]
    )
}

struct SimpleEQGet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Print bass / mid / treble in dB.")
    @OptionGroup var global: GlobalOptions
    func run() {
        let data = sendCommand(["command": "simpleEQ.get"])
        let eq = data["simpleEQ"] as? [String: Any] ?? [:]
        emit(data, json: global.json,
             human: "bass \(formatDB(eq["bass"]))   mid \(formatDB(eq["mid"]))   treble \(formatDB(eq["treble"]))")
    }
}

struct SimpleEQSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set bass / mid / treble in dB (-24…+24). Omitted bands are left unchanged.")
    // `.unconditional` so `--bass -3` reads -3 as the value, not as a flag.
    @Option(parsing: .unconditional, help: "Bass gain in dB.") var bass: Double?
    @Option(parsing: .unconditional, help: "Mid gain in dB.") var mid: Double?
    @Option(parsing: .unconditional, help: "Treble gain in dB.") var treble: Double?
    @OptionGroup var global: GlobalOptions

    func run() {
        var request: [String: Any] = ["command": "simpleEQ.set"]
        if let bass { request["bass"] = bass }
        if let mid { request["mid"] = mid }
        if let treble { request["treble"] = treble }
        guard request.count > 1 else {
            die("Provide at least one of --bass, --mid, --treble.", .invalid)
        }
        let data = sendCommand(request)
        let eq = data["simpleEQ"] as? [String: Any] ?? [:]
        emit(data, json: global.json,
             human: "bass \(formatDB(eq["bass"]))   mid \(formatDB(eq["mid"]))   treble \(formatDB(eq["treble"]))")
    }
}

// MARK: - profiles

struct Profiles: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List, inspect, switch, import, and export profiles.",
        subcommands: [ProfilesList.self, ProfilesActive.self, ProfilesActivate.self, ProfilesImport.self, ProfilesExport.self]
    )
}

struct ProfilesList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List available profiles.")
    @OptionGroup var global: GlobalOptions
    func run() {
        let data = sendCommand(["command": "profiles.list"])
        let profiles = data["profiles"] as? [[String: Any]] ?? []
        if global.json { emitJSON(data); return }
        if profiles.isEmpty { print("No profiles."); return }
        for p in profiles {
            let marker = (p["active"] as? Bool) == true ? "*" : " "
            let name = p["name"] as? String ?? "?"
            let tag = (p["builtIn"] as? Bool) == true ? "  (built-in)" : ""
            print("\(marker) \(name)\(tag)")
        }
    }
}

struct ProfilesActive: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "active", abstract: "Print the active profile.")
    @OptionGroup var global: GlobalOptions
    func run() {
        let data = sendCommand(["command": "profiles.active"])
        if global.json { emitJSON(data); return }
        if let p = data["profile"] as? [String: Any], let name = p["name"] as? String {
            print(name + ((p["builtIn"] as? Bool) == true ? " (built-in)" : ""))
        } else {
            print("none")
        }
    }
}

struct ProfilesActivate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "activate", abstract: "Activate a profile by name.")
    @Argument(help: "Profile name.") var name: String
    @OptionGroup var global: GlobalOptions
    func run() {
        let data = sendCommand(["command": "profiles.activate", "name": name])
        let activated = (data["activated"] as? [String: Any])?["name"] as? String ?? name
        emit(data, json: global.json, human: "Activated \(activated)")
    }
}

struct ProfilesImport: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import", abstract: "Import a profile from a JSON file.")
    @Argument(help: "Path to a profile JSON file.") var file: String
    @OptionGroup var global: GlobalOptions
    func run() {
        let data = sendCommand(["command": "profiles.import", "path": absolutePath(file)])
        let name = (data["imported"] as? [String: Any])?["name"] as? String ?? "profile"
        emit(data, json: global.json, human: "Imported \(name)")
    }
}

struct ProfilesExport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export a profile (or --all) to a JSON file."
    )
    @Flag(name: .long, help: "Export every profile to one JSON file.")
    var all = false
    @Argument(help: "Profile name (omit with --all), then the output file path.")
    var args: [String] = []
    @OptionGroup var global: GlobalOptions

    func run() {
        var request: [String: Any] = ["command": "profiles.export"]
        let path: String
        if all {
            guard args.count == 1 else {
                die("Usage: sherlockeq profiles export --all <file>", .invalid)
            }
            path = args[0]
            request["all"] = true
        } else {
            guard args.count == 2 else {
                die("Usage: sherlockeq profiles export <name> <file>  (or --all <file>)", .invalid)
            }
            request["name"] = args[0]
            path = args[1]
        }
        let resolved = absolutePath(path)
        request["path"] = resolved
        let data = sendCommand(request)
        emit(data, json: global.json, human: "Exported to \(resolved)")
    }
}

// MARK: - devices

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List output devices or show the current one.",
        subcommands: [DevicesList.self, DevicesCurrent.self]
    )
}

struct DevicesList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List available output devices.")
    @OptionGroup var global: GlobalOptions
    func run() {
        let data = sendCommand(["command": "devices.list"])
        let devices = data["devices"] as? [[String: Any]] ?? []
        if global.json { emitJSON(data); return }
        if devices.isEmpty { print("No output devices."); return }
        for d in devices {
            let marker = (d["current"] as? Bool) == true ? "*" : " "
            print("\(marker) \(d["name"] as? String ?? "?")")
        }
    }
}

struct DevicesCurrent: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "current", abstract: "Show the current output device.")
    @OptionGroup var global: GlobalOptions
    func run() {
        let data = sendCommand(["command": "devices.current"])
        if global.json { emitJSON(data); return }
        let name = (data["device"] as? [String: Any])?["name"] as? String ?? "?"
        print(name)
    }
}

// MARK: - reset

struct Reset: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Reset app settings to defaults. Your saved profiles are kept."
    )
    @Flag(name: .long, help: "Reset app preferences and engine settings to defaults.")
    var settings = false
    @Flag(name: [.customShort("y"), .long], help: "Skip the confirmation prompt.")
    var yes = false
    @OptionGroup var global: GlobalOptions

    func run() {
        guard settings else {
            die("Nothing to reset. Did you mean `sherlockeq reset --settings`?", .invalid)
        }
        if !yes {
            if global.json {
                die("Refusing to reset in --json mode without --yes.", .invalid)
            }
            FileHandle.standardError.write(Data("Reset SherlockEQ settings to defaults? Profiles are kept. [y/N] ".utf8))
            let answer = readLine() ?? ""
            guard ["y", "Y", "yes", "YES"].contains(answer) else {
                die("Aborted.")
            }
        }
        let data = sendCommand(["command": "reset.settings"])
        emit(data, json: global.json, human: "Settings reset to defaults.")
    }
}

// MARK: - install / uninstall

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Symlink this sherlockeq binary into a directory on your PATH."
    )
    @Option(name: .long, help: "Directory to link into (default: /usr/local/bin).")
    var prefix = "/usr/local/bin"
    @OptionGroup var global: GlobalOptions

    func run() {
        guard let selfURL = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            die("Could not determine this binary's path.")
        }
        let dir = URL(fileURLWithPath: (prefix as NSString).expandingTildeInPath, isDirectory: true)
        let link = dir.appendingPathComponent("sherlockeq")
        let fm = FileManager.default

        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                manualHint(selfURL, link)
            }
        }
        // Replace only a prior symlink — never clobber an unrelated regular
        // file at that path. (`attributesOfItem` uses lstat, so it reports the
        // link itself, not its target.) The old `|| lastPathComponent ==
        // "sherlockeq"` clause was always true — `link` is literally
        // `<dir>/sherlockeq` — so the refusal could never fire and a real file
        // named `sherlockeq` on the user's PATH would be silently deleted.
        if let info = try? fm.attributesOfItem(atPath: link.path) {
            let isSymlink = (info[.type] as? FileAttributeType) == .typeSymbolicLink
            guard isSymlink else {
                die("\(link.path) already exists and is not a sherlockeq symlink. Refusing to overwrite.")
            }
            try? fm.removeItem(at: link)
        }
        do {
            try fm.createSymbolicLink(at: link, withDestinationURL: selfURL)
        } catch {
            manualHint(selfURL, link)
        }
        emit(["installed": link.path, "target": selfURL.path], json: global.json,
             human: "Linked \(link.path) → \(selfURL.path)")
    }

    private func manualHint(_ selfURL: URL, _ link: URL) -> Never {
        die("""
            Couldn't write \(link.path) (permission?). Run it yourself:
              sudo ln -sf "\(selfURL.path)" "\(link.path)"
            """)
    }
}

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove a sherlockeq symlink created by `install`."
    )
    @Option(name: .long, help: "Directory to remove the link from (default: /usr/local/bin).")
    var prefix = "/usr/local/bin"
    @OptionGroup var global: GlobalOptions

    func run() {
        let dir = URL(fileURLWithPath: (prefix as NSString).expandingTildeInPath, isDirectory: true)
        let link = dir.appendingPathComponent("sherlockeq")
        let fm = FileManager.default
        guard let info = try? fm.attributesOfItem(atPath: link.path) else {
            emit(["removed": false], json: global.json, human: "No sherlockeq link at \(link.path).")
            return
        }
        guard (info[.type] as? FileAttributeType) == .typeSymbolicLink else {
            die("\(link.path) is not a symlink. Refusing to remove it.")
        }
        do {
            try fm.removeItem(at: link)
        } catch {
            die("Couldn't remove \(link.path) (permission?). Run: sudo rm \"\(link.path)\"")
        }
        emit(["removed": true, "path": link.path], json: global.json, human: "Removed \(link.path).")
    }
}
