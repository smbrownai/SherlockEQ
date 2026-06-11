import AppKit
import Foundation

/// Decodes a JSON request from the `sherlockeq` CLI, performs it against the
/// live app state, and encodes a JSON reply. Every read and mutation goes
/// through the existing `AudioState` / `ProfileStore` surface — there is no
/// second DSP path and no direct file editing here — so the GUI updates the
/// moment a command lands.
///
/// Wire protocol (both directions are a single JSON object):
///   request : { "command": "<verb>", ...args }
///   reply   : { "ok": true,  "data": { ... } }
///           | { "ok": false, "code": "<machine_code>", "error": "<message>" }
///
/// The `code` lets the CLI choose an exit status without string-matching.
@MainActor
final class CLICommandHandler {

    private unowned let audioState: AudioState
    private unowned let profileStore: ProfileStore

    init(audioState: AudioState, profileStore: ProfileStore) {
        self.audioState = audioState
        self.profileStore = profileStore
    }

    // Simple-EQ band layout — must match the app's Simple mode slots
    // (HearingProfile.EQMode.ownedSlots) so the CLI edits the same bands the
    // GUI's Simple sliders do.
    private struct SimpleSlot {
        let key: String
        let frequencyHz: Double
        let filterType: EQFilterType
    }
    private static let simpleSlots = [
        SimpleSlot(key: "bass",   frequencyHz: 250,  filterType: .lowShelf),
        SimpleSlot(key: "mid",    frequencyHz: 1000, filterType: .parametric),
        SimpleSlot(key: "treble", frequencyHz: 5000, filterType: .highShelf),
    ]
    private static let simpleBandwidth = 1.0

    // MARK: - Entry point

    func handle(_ requestData: Data) -> Data {
        guard
            let object = try? JSONSerialization.jsonObject(with: requestData),
            let request = object as? [String: Any],
            let command = request["command"] as? String
        else {
            return Self.fail(code: "bad_request", "Malformed or missing command.")
        }

        switch command {
        case "status":              return status()
        case "diagnostics":         return diagnostics()
        case "bypass.get":          return bypassGet()
        case "bypass.set":          return bypassSet(request)
        case "profiles.list":       return profilesList()
        case "profiles.active":     return profilesActive()
        case "profiles.activate":   return profilesActivate(request)
        case "profiles.import":     return profilesImport(request)
        case "profiles.export":     return profilesExport(request)
        case "devices.list":        return devicesList()
        case "devices.current":     return devicesCurrent()
        case "gain.get":            return gainGet()
        case "gain.set":            return gainSet(request)
        case "balance.get":         return balanceGet()
        case "balance.set":         return balanceSet(request)
        case "simpleEQ.get":        return simpleEQGet()
        case "simpleEQ.set":        return simpleEQSet(request)
        case "quit":                return quit()
        case "reset.settings":      return resetSettings()
        default:
            return Self.fail(code: "unknown_command", "Unknown command: \(command).")
        }
    }

    // MARK: - Status / diagnostics

    private func status() -> Data {
        Self.ok(statusFields())
    }

    private func diagnostics() -> Data {
        var data = statusFields()
        let info = Bundle.main.infoDictionary
        data["app"] = [
            "version": info?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": info?["CFBundleVersion"] as? String ?? "unknown",
            "bundleID": Bundle.main.bundleIdentifier ?? "unknown",
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
        ]
        data["system"] = [
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "hostName": ProcessInfo.processInfo.hostName,
        ]
        data["profilesDirectory"] = profileStore.storageDirectory.path
        data["profileCount"] = profileStore.profiles.count
        data["builtInProfileCount"] = profileStore.profiles.filter { $0.isBuiltIn }.count
        data["schemaVersion"] = 1
        return Self.ok(data)
    }

    /// The shared core both `status` and `diagnostics` report.
    private func statusFields() -> [String: Any] {
        let profile = audioState.activeProfile(in: profileStore)
        var fields: [String: Any] = [
            "running": true,
            "processing": isProcessing,
            "tapState": tapStateString,
            "bypass": audioState.referenceMode,
            "gainDB": audioState.masterGainDB,
            "outputDevice": [
                "name": audioState.tap.currentOutputDeviceName,
                "id": Int(audioState.tap.currentOutputDeviceID),
            ],
        ]
        if let profile {
            fields["profile"] = [
                "name": profile.name,
                "id": profile.id.uuidString,
                "builtIn": profile.isBuiltIn,
            ]
            fields["balance"] = profile.balance
            fields["simpleEQ"] = simpleEQValues(of: profile)
        } else {
            fields["profile"] = NSNull()
        }
        return fields
    }

    private var isProcessing: Bool {
        if case .running = audioState.tap.state { return true }
        return false
    }

    private var tapStateString: String {
        switch audioState.tap.state {
        case .idle:               return "idle"
        case .awaitingPermission: return "awaiting_permission"
        case .permissionDenied:   return "permission_denied"
        case .starting:           return "starting"
        case .running:            return "running"
        case .failed(let reason): return "failed: \(reason)"
        }
    }

    // MARK: - Bypass (reference mode)

    private func bypassGet() -> Data {
        Self.ok(["bypass": audioState.referenceMode])
    }

    private func bypassSet(_ request: [String: Any]) -> Data {
        guard let mode = request["mode"] as? String else {
            return Self.fail(code: "invalid_argument", "Missing bypass mode.")
        }
        switch mode {
        case "on":     audioState.referenceMode = true
        case "off":    audioState.referenceMode = false
        case "toggle": audioState.referenceMode.toggle()
        default:       return Self.fail(code: "invalid_argument", "Expected on, off, or toggle.")
        }
        return Self.ok(["bypass": audioState.referenceMode])
    }

    // MARK: - Profiles

    private func profilesList() -> Data {
        let active = audioState.activeProfileID
        let list = profileStore.profiles.map { p -> [String: Any] in
            [
                "name": p.name,
                "id": p.id.uuidString,
                "builtIn": p.isBuiltIn,
                "active": p.id == active,
            ]
        }
        return Self.ok(["profiles": list])
    }

    private func profilesActive() -> Data {
        guard let profile = audioState.activeProfile(in: profileStore) else {
            return Self.ok(["profile": NSNull()])
        }
        return Self.ok(["profile": [
            "name": profile.name,
            "id": profile.id.uuidString,
            "builtIn": profile.isBuiltIn,
        ]])
    }

    private func profilesActivate(_ request: [String: Any]) -> Data {
        guard let name = request["name"] as? String, !name.isEmpty else {
            return Self.fail(code: "invalid_argument", "Missing profile name.")
        }
        switch resolveProfile(named: name) {
        case .found(let profile):
            audioState.activeProfileID = profile.id
            return Self.ok(["activated": ["name": profile.name, "id": profile.id.uuidString]])
        case .error(let response):
            return response
        }
    }

    private func profilesImport(_ request: [String: Any]) -> Data {
        guard let path = request["path"] as? String, !path.isEmpty else {
            return Self.fail(code: "invalid_argument", "Missing file path.")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Self.fail(code: "not_found", "No such file: \(path)")
        }
        do {
            let imported = try profileStore.importProfile(from: url)
            return Self.ok(["imported": ["name": imported.name, "id": imported.id.uuidString]])
        } catch {
            return Self.fail(code: "import_failed", "Could not import profile: \(error.localizedDescription)")
        }
    }

    private func profilesExport(_ request: [String: Any]) -> Data {
        guard let path = request["path"] as? String, !path.isEmpty else {
            return Self.fail(code: "invalid_argument", "Missing file path.")
        }
        let url = URL(fileURLWithPath: path)
        let all = (request["all"] as? Bool) ?? false

        if all {
            // No single-file bundle format exists in the app; the CLI is the
            // only producer, so write a JSON array of every profile. (Import
            // still takes a single-profile file, matching the app's format.)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            do {
                let data = try encoder.encode(profileStore.profiles)
                try data.write(to: url, options: .atomic)
                return Self.ok(["exported": ["count": profileStore.profiles.count, "path": url.path]])
            } catch {
                return Self.fail(code: "export_failed", "Could not export profiles: \(error.localizedDescription)")
            }
        }

        guard let name = request["name"] as? String, !name.isEmpty else {
            return Self.fail(code: "invalid_argument", "Provide a profile name or --all.")
        }
        switch resolveProfile(named: name) {
        case .found(let profile):
            do {
                try profileStore.exportProfile(profile, to: url)
                return Self.ok(["exported": ["name": profile.name, "path": url.path]])
            } catch {
                return Self.fail(code: "export_failed", "Could not export profile: \(error.localizedDescription)")
            }
        case .error(let response):
            return response
        }
    }

    /// Outcome of a name lookup: either the profile, or a ready-to-send error
    /// reply (not found / ambiguous). Avoids `Result`, whose failure must be
    /// an `Error` — here the failure is already an encoded JSON reply.
    private enum ProfileResolution {
        case found(HearingProfile)
        case error(Data)
    }

    /// Resolve a profile by name: exact match first, then a single
    /// case-insensitive match.
    private func resolveProfile(named name: String) -> ProfileResolution {
        if let exact = profileStore.profiles.first(where: { $0.name == name }) {
            return .found(exact)
        }
        let lower = name.lowercased()
        let matches = profileStore.profiles.filter { $0.name.lowercased() == lower }
        switch matches.count {
        case 0:  return .error(Self.fail(code: "not_found", "No profile named \"\(name)\"."))
        case 1:  return .found(matches[0])
        default: return .error(Self.fail(code: "ambiguous", "Multiple profiles named \"\(name)\" — names differ only by case."))
        }
    }

    // MARK: - Devices

    private func devicesList() -> Data {
        let current = audioState.tap.currentOutputDeviceID
        let list = CATapEngine.allOutputDevices().map { d -> [String: Any] in
            [
                "name": d.name,
                "uid": d.uid,
                "id": Int(d.id),
                "current": d.id == current,
            ]
        }
        return Self.ok(["devices": list])
    }

    private func devicesCurrent() -> Data {
        Self.ok(["device": [
            "name": audioState.tap.currentOutputDeviceName,
            "id": Int(audioState.tap.currentOutputDeviceID),
        ]])
    }

    // MARK: - Gain

    private func gainGet() -> Data {
        Self.ok(["gainDB": audioState.masterGainDB])
    }

    private func gainSet(_ request: [String: Any]) -> Data {
        guard let db = Self.number(request["db"]) else {
            return Self.fail(code: "invalid_argument", "Missing or non-numeric gain value.")
        }
        guard (-60...12).contains(db) else {
            return Self.fail(code: "out_of_range", "Gain must be between -60 and +12 dB.")
        }
        audioState.masterGainDB = db
        return Self.ok(["gainDB": audioState.masterGainDB])
    }

    // MARK: - Balance

    private func balanceGet() -> Data {
        guard let profile = audioState.activeProfile(in: profileStore) else {
            return Self.fail(code: "no_active_profile", "No active profile to read balance from.")
        }
        return Self.ok(["balance": profile.balance])
    }

    private func balanceSet(_ request: [String: Any]) -> Data {
        guard let value = Self.number(request["value"]) else {
            return Self.fail(code: "invalid_argument", "Missing or non-numeric balance value.")
        }
        guard (-1.0...1.0).contains(value) else {
            return Self.fail(code: "out_of_range", "Balance must be between -1 (left) and 1 (right).")
        }
        guard var profile = audioState.activeProfile(in: profileStore) else {
            return Self.fail(code: "no_active_profile", "No active profile to set balance on.")
        }
        profile.balance = value
        do {
            try profileStore.save(profile)
            return Self.ok(["balance": value])
        } catch {
            return Self.fail(code: "save_failed", "Could not save profile: \(error.localizedDescription)")
        }
    }

    // MARK: - Simple EQ

    private func simpleEQGet() -> Data {
        guard let profile = audioState.activeProfile(in: profileStore) else {
            return Self.fail(code: "no_active_profile", "No active profile to read EQ from.")
        }
        return Self.ok(["simpleEQ": simpleEQValues(of: profile)])
    }

    private func simpleEQSet(_ request: [String: Any]) -> Data {
        guard var profile = audioState.activeProfile(in: profileStore) else {
            return Self.fail(code: "no_active_profile", "No active profile to set EQ on.")
        }
        // Only the bands that were provided are changed; omitted bands keep
        // their current value. At least one must be present.
        var applied: [String: Double] = [:]
        for slot in Self.simpleSlots {
            guard request[slot.key] != nil else { continue }
            guard let db = Self.number(request[slot.key]) else {
                return Self.fail(code: "invalid_argument", "Non-numeric value for \(slot.key).")
            }
            guard (-24.0...24.0).contains(db) else {
                return Self.fail(code: "out_of_range", "\(slot.key) must be between -24 and +24 dB.")
            }
            applied[slot.key] = db
        }
        guard !applied.isEmpty else {
            return Self.fail(code: "invalid_argument", "Provide at least one of --bass, --mid, --treble.")
        }
        EQBandLookup.mutateBothEars(of: &profile) { bands in
            for slot in Self.simpleSlots {
                guard let db = applied[slot.key] else { continue }
                EQBandLookup.setGain(db, at: slot.frequencyHz, bandwidth: Self.simpleBandwidth,
                                     filterType: slot.filterType, in: &bands)
            }
        }
        do {
            try profileStore.save(profile)
            return Self.ok(["simpleEQ": simpleEQValues(of: profile)])
        } catch {
            return Self.fail(code: "save_failed", "Could not save profile: \(error.localizedDescription)")
        }
    }

    private func simpleEQValues(of profile: HearingProfile) -> [String: Double] {
        var out: [String: Double] = [:]
        for slot in Self.simpleSlots {
            out[slot.key] = EQBandLookup.gain(at: slot.frequencyHz, filterType: slot.filterType,
                                              in: profile.leftEar.bands)
        }
        return out
    }

    // MARK: - Lifecycle

    private func quit() -> Data {
        // Reply first, then terminate on the next run-loop turn so the CLI
        // actually receives the acknowledgement before the port goes away.
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return Self.ok(["quitting": true])
    }

    private func resetSettings() -> Data {
        audioState.resetSettingsToDefaults()
        return Self.ok(["reset": "settings"])
    }

    // MARK: - Reply encoding

    private static func ok(_ data: [String: Any]) -> Data {
        encode(["ok": true, "data": data])
    }

    private static func fail(code: String, _ message: String) -> Data {
        encode(["ok": false, "code": code, "error": message])
    }

    private static func encode(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]))
            ?? Data(#"{"ok":false,"code":"encode_failed","error":"Could not encode reply."}"#.utf8)
    }

    /// Accept JSON numbers whether they arrive as Double or Int.
    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}
