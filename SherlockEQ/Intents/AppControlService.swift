import Foundation

/// A failure from the shared control layer. Carries a stable machine `code`
/// (the `sherlockeq` CLI maps it to an exit status; App Intents surface the
/// `message`) plus a human-readable message.
struct ControlError: LocalizedError {
    let code: String
    let message: String
    init(code: String, _ message: String) {
        self.code = code
        self.message = message
    }
    var errorDescription: String? { message }
}

/// Reference-mode (bypass) action.
enum BypassMode {
    case on, off, toggle
}

/// Transport-agnostic control surface over the live `AudioState` / `ProfileStore`.
///
/// Both doorways into a running SherlockEQ adapt to this one API:
/// - `CLICommandHandler` is the JSON-over-CFMessagePort adapter for the
///   `sherlockeq` CLI.
/// - the App Intents in `SherlockEQ/Intents/` are the typed adapter for
///   Shortcuts / Siri / Spotlight.
///
/// Keeping the ranges, the Simple-EQ slot layout, the profile-name resolution,
/// and the save-error mapping here means the two adapters can't disagree about
/// what a valid request is. There is no second DSP path — every mutation goes
/// through the same `AudioState` / `ProfileStore` the GUI uses, so the UI
/// updates live.
@MainActor
struct AppControlService {

    unowned let audioState: AudioState
    unowned let profileStore: ProfileStore

    init(audioState: AudioState, profileStore: ProfileStore) {
        self.audioState = audioState
        self.profileStore = profileStore
    }

    // MARK: - Live lookup

    /// The service bound to the running app's singletons, or nil if the app
    /// hasn't reached `applicationDidFinishLaunching` yet.
    static var live: AppControlService? {
        guard let app = AppDelegate.shared else { return nil }
        return AppControlService(audioState: app.audioState, profileStore: app.profileStore)
    }

    /// Resolve the live service, waiting for the app to finish launching.
    ///
    /// When a Shortcut fires while SherlockEQ isn't running, the system
    /// background-launches the app to perform the intent; this polls until the
    /// delegate's singletons exist (so the EQ is actually engaged) and throws
    /// `not_running` only if the launch never completes.
    static func awaitLive(timeout: Duration = .seconds(12)) async throws -> AppControlService {
        if let service = live { return service }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            if let service = live { return service }
        }
        throw ControlError(code: "not_running", "SherlockEQ could not be reached.")
    }

    /// All profiles known to the app, preferring the live store and falling
    /// back to a fresh disk read so a Shortcuts profile picker can populate
    /// even before the app is fully up.
    static func snapshotProfiles() -> [HearingProfile] {
        if let service = live { return service.allProfiles() }
        let store = ProfileStore(directory: ProfileStore.bootDirectory())
        _ = store.loadAll()
        return store.profiles
    }

    // MARK: - Validation ranges / Simple-EQ layout

    static let gainRange: ClosedRange<Double> = -60...12
    static let balanceRange: ClosedRange<Double> = -1...1
    static let simpleEQRange: ClosedRange<Double> = -24...24

    /// Simple-EQ band layout — must match the app's Simple mode slots
    /// (`HearingProfile.EQMode.ownedSlots`) so both adapters edit the same
    /// bands the GUI's Simple sliders do.
    struct SimpleSlot {
        let key: String
        let frequencyHz: Double
        let filterType: EQFilterType
    }
    static let simpleSlots = [
        SimpleSlot(key: "bass",   frequencyHz: 250,  filterType: .lowShelf),
        SimpleSlot(key: "mid",    frequencyHz: 1000, filterType: .parametric),
        SimpleSlot(key: "treble", frequencyHz: 5000, filterType: .highShelf),
    ]
    static let simpleBandwidth = 1.0

    // MARK: - Reference mode (bypass)

    var bypass: Bool { audioState.referenceMode }

    @discardableResult
    func setBypass(_ mode: BypassMode) -> Bool {
        switch mode {
        case .on:     audioState.referenceMode = true
        case .off:    audioState.referenceMode = false
        case .toggle: audioState.referenceMode.toggle()
        }
        return audioState.referenceMode
    }

    // MARK: - Master gain

    var gainDB: Double { audioState.masterGainDB }

    @discardableResult
    func setGain(_ db: Double) throws -> Double {
        guard Self.gainRange.contains(db) else {
            throw ControlError(code: "out_of_range", "Gain must be between -60 and +12 dB.")
        }
        audioState.masterGainDB = db
        return audioState.masterGainDB
    }

    /// Nudge gain by a relative amount, clamped into the valid range.
    @discardableResult
    func adjustGain(by delta: Double) -> Double {
        let next = min(max(audioState.masterGainDB + delta, Self.gainRange.lowerBound), Self.gainRange.upperBound)
        audioState.masterGainDB = next
        return next
    }

    // MARK: - Balance

    func currentBalance() throws -> Double {
        guard let profile = audioState.activeProfile(in: profileStore) else {
            throw ControlError(code: "no_active_profile", "No active profile.")
        }
        return profile.balance
    }

    @discardableResult
    func setBalance(_ value: Double) throws -> Double {
        guard Self.balanceRange.contains(value) else {
            throw ControlError(code: "out_of_range", "Balance must be between -1 (left) and 1 (right).")
        }
        guard var profile = audioState.activeProfile(in: profileStore) else {
            throw ControlError(code: "no_active_profile", "No active profile.")
        }
        profile.balance = value
        try saveTracking(profile)
        return value
    }

    // MARK: - Profiles

    func allProfiles() -> [HearingProfile] { profileStore.profiles }

    var activeProfileID: UUID? { audioState.activeProfileID }

    func activeProfile() -> HearingProfile? { audioState.activeProfile(in: profileStore) }

    /// Exact-name match first, then a single case-insensitive match.
    func resolveProfile(named name: String) throws -> HearingProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ControlError(code: "invalid_argument", "Missing profile name.")
        }
        if let exact = profileStore.profiles.first(where: { $0.name == trimmed }) {
            return exact
        }
        let lower = trimmed.lowercased()
        let matches = profileStore.profiles.filter { $0.name.lowercased() == lower }
        switch matches.count {
        case 0:  throw ControlError(code: "not_found", "No profile named \"\(trimmed)\".")
        case 1:  return matches[0]
        default: throw ControlError(code: "ambiguous", "Multiple profiles named \"\(trimmed)\" — names differ only by case.")
        }
    }

    func profile(id: UUID) throws -> HearingProfile {
        guard let profile = profileStore.profiles.first(where: { $0.id == id }) else {
            throw ControlError(code: "not_found", "No profile with that identifier.")
        }
        return profile
    }

    func activate(_ profile: HearingProfile) {
        audioState.activeProfileID = profile.id
    }

    // MARK: - Simple EQ

    func simpleEQValues(of profile: HearingProfile) -> [String: Double] {
        var out: [String: Double] = [:]
        for slot in Self.simpleSlots {
            out[slot.key] = EQBandLookup.gain(at: slot.frequencyHz, filterType: slot.filterType,
                                              in: profile.leftEar.bands)
        }
        return out
    }

    func currentSimpleEQ() throws -> [String: Double] {
        guard let profile = audioState.activeProfile(in: profileStore) else {
            throw ControlError(code: "no_active_profile", "No active profile.")
        }
        return simpleEQValues(of: profile)
    }

    /// Set any subset of bass / mid / treble (nil leaves a band unchanged). At
    /// least one must be provided.
    @discardableResult
    func setSimpleEQ(bass: Double?, mid: Double?, treble: Double?) throws -> [String: Double] {
        guard var profile = audioState.activeProfile(in: profileStore) else {
            throw ControlError(code: "no_active_profile", "No active profile.")
        }
        let requested: [String: Double?] = ["bass": bass, "mid": mid, "treble": treble]
        var applied: [String: Double] = [:]
        for slot in Self.simpleSlots {
            guard let db = requested[slot.key] ?? nil else { continue }
            guard Self.simpleEQRange.contains(db) else {
                throw ControlError(code: "out_of_range", "\(slot.key) must be between -24 and +24 dB.")
            }
            applied[slot.key] = db
        }
        guard !applied.isEmpty else {
            throw ControlError(code: "invalid_argument", "Provide at least one of bass, mid, treble.")
        }
        EQBandLookup.mutateBothEars(of: &profile) { bands in
            for slot in Self.simpleSlots {
                guard let db = applied[slot.key] else { continue }
                EQBandLookup.setGain(db, at: slot.frequencyHz, bandwidth: Self.simpleBandwidth,
                                     filterType: slot.filterType, in: &bands)
            }
        }
        try saveTracking(profile)
        return simpleEQValues(of: profile)
    }

    // MARK: - Output device

    var outputDeviceName: String { audioState.tap.currentOutputDeviceName }

    // MARK: - Helpers

    private func saveTracking(_ profile: HearingProfile) throws {
        do {
            try profileStore.save(profile)
        } catch {
            throw ControlError(code: "save_failed", "Could not save profile: \(error.localizedDescription)")
        }
    }
}
