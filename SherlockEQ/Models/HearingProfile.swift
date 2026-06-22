import Foundation

/// The central data object. One profile per (output device, context, activity)
/// per the spec — users can create as many as they like and switch between them.
struct HearingProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var symbol: String                          // SF Symbol name shown in the sidebar/picker
    var linkedDeviceUID: String?                // optional auto-switch target

    var leftEar: EarProfile
    var rightEar: EarProfile
    /// Per-ear tinnitus notch. Defaults are .disabled. When
    /// `separateNotch` is false (the common case) the UI keeps both
    /// in sync — every edit writes the same value to both. When true,
    /// the user can dial in different notches per ear, e.g. for
    /// unilateral tinnitus or asymmetric pitch.
    var leftNotch: TinnitusNotch
    var rightNotch: TinnitusNotch
    /// When true, the Tinnitus Notch UI exposes two notch panels (L
    /// and R) and the "Set as Notch" button gains a three-way picker
    /// (Left / Right / Both). When false, one panel writes both
    /// ears in lockstep.
    var separateNotch: Bool
    /// Level-dependent dynamic processors (Speech Presence / Harshness
    /// Control / Sibilance Tamer). Follows the tinnitus-notch pattern:
    /// dedicated fields folded into the audio path at `applyProfile`
    /// time, deliberately NOT stored as `EarProfile.bands`. Defaults to
    /// all-disabled; decoded with `decodeIfPresent` for backward compat.
    var dynamics: DynamicProcessingSettings
    var globalTrimDB: Double                    // -12 to +12 — guards against post-boost clipping
    var balance: Double                         // -1 (full L) … 0 (centered) … +1 (full R)
    var autoEQCurveURL: URL?                    // legacy — kept for decoder compat, no longer read
    var autoEQName: String?                     // display label for the loaded AutoEQ correction
    var autoEQBands: [EQBand]?                  // parsed AutoEQ bands; applied per-ear upstream of profile EQ
    var autoEQPreampDB: Double?                 // headroom adjustment baked into the AutoEQ file
    /// AutoEQ catalog `path` the correction was applied from, if any. Stored so
    /// the saved-profiles UI can identify "this entry is the one applied" by an
    /// unambiguous key — the catalog has duplicate display names across
    /// source/type (e.g. the same model from oratory1990 and Crinacle), so a
    /// name match alone can point at the wrong correction. decodeIfPresent.
    var autoEQSourcePath: String?
    var safeListeningCeilingDB: Double          // user-set, default 85.0
    var compensationFactor: Double              // 0.25–1.0 — audiogram→EQ strength
    /// When true, EQ tabs show per-ear sliders; when false, every edit
    /// applies to both ears in lockstep. Lives on the profile because
    /// the audiogram itself is per-ear — symmetric-hearing users keep
    /// this off and avoid a row of duplicate sliders; asymmetric-
    /// hearing users flip it on per-profile without a global setting.
    /// Toggling the value never mutates band data; only future edits
    /// in the new mode propagate to one or both ears.
    var separateChannels: Bool                  // default false — single column UI
    /// Which EQ "lens" this profile uses. The four modes are storage
    /// views onto the same band array, not stackable layers — the
    /// profile commits to one mental model (quick tone-shaping with
    /// Simple, voice-tuned with Speech, graphic-EQ with Advanced,
    /// full parametric with Expert). Switching is non-destructive:
    /// bands the other modes wrote stay in storage and only hide.
    var eqMode: EQMode                          // new profiles default .simple; legacy decode .expert
    /// Marks one of the shipped factory listening presets. No longer a
    /// read-only lock — factory presets are editable in place. The flag
    /// only enables the per-profile "Reset to Factory Default" affordance
    /// and inclusion in "Restore Factory Presets". User-created profiles
    /// (and copies) have this false and get neither.
    var isBuiltIn: Bool
    /// One-sentence, user-facing blurb shown on profile cards. Populated
    /// for factory presets; nil for user profiles. decodeIfPresent.
    var presetDescription: String?
    /// Best-use tags ("Voice", "Music", "Comfort", …) shown as chips on
    /// profile cards. Empty for user profiles. decodeIfPresent.
    var presetTags: [String]

    var createdAt: Date
    var modifiedAt: Date

    /// Legacy keys that the synthesised CodingKeys (which mirrors only
    /// current stored properties) doesn't include. Used by the custom
    /// decoder to read old field names off disk.
    private enum LegacyKeys: String, CodingKey {
        case notch
    }

    // Custom decoder so older profile JSON (pre-balance, pre-isBuiltIn) still
    // loads — missing fields decode to safe defaults. Encoding stays synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id                     = try c.decode(UUID.self, forKey: .id)
        self.name                   = try c.decode(String.self, forKey: .name)
        self.symbol                 = try c.decode(String.self, forKey: .symbol)
        self.linkedDeviceUID        = try c.decodeIfPresent(String.self, forKey: .linkedDeviceUID)
        self.leftEar                = try c.decode(EarProfile.self, forKey: .leftEar)
        self.rightEar               = try c.decode(EarProfile.self, forKey: .rightEar)
        // Per-ear notch. Legacy profiles stored one shared `notch`
        // field; mirror it onto both ears so old data keeps behaving
        // exactly as it did. New profiles persist `leftNotch` /
        // `rightNotch` explicitly.
        if let lN = try c.decodeIfPresent(TinnitusNotch.self, forKey: .leftNotch),
           let rN = try c.decodeIfPresent(TinnitusNotch.self, forKey: .rightNotch) {
            self.leftNotch  = lN
            self.rightNotch = rN
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let shared = try legacy.decode(TinnitusNotch.self, forKey: .notch)
            self.leftNotch  = shared
            self.rightNotch = shared
        }
        self.separateNotch          = try c.decodeIfPresent(Bool.self, forKey: .separateNotch) ?? false
        self.dynamics               = try c.decodeIfPresent(DynamicProcessingSettings.self, forKey: .dynamics) ?? .init()
        self.globalTrimDB           = try c.decode(Double.self, forKey: .globalTrimDB)
        self.balance                = try c.decodeIfPresent(Double.self, forKey: .balance) ?? 0
        self.autoEQCurveURL         = try c.decodeIfPresent(URL.self, forKey: .autoEQCurveURL)
        self.autoEQName             = try c.decodeIfPresent(String.self, forKey: .autoEQName)
        self.autoEQBands            = try c.decodeIfPresent([EQBand].self, forKey: .autoEQBands)
        self.autoEQPreampDB         = try c.decodeIfPresent(Double.self, forKey: .autoEQPreampDB)
        self.autoEQSourcePath       = try c.decodeIfPresent(String.self, forKey: .autoEQSourcePath)
        self.safeListeningCeilingDB = try c.decode(Double.self, forKey: .safeListeningCeilingDB)
        self.compensationFactor     = try c.decode(Double.self, forKey: .compensationFactor)
        self.separateChannels       = try c.decodeIfPresent(Bool.self, forKey: .separateChannels) ?? false
        // Legacy profiles default to .expert so users who edited bands
        // across multiple tabs in the old multi-tab world still see
        // everything on first load. New profiles created via init
        // default to .simple — see the designated initializer.
        self.eqMode                 = try c.decodeIfPresent(EQMode.self, forKey: .eqMode) ?? .expert
        self.isBuiltIn              = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        self.presetDescription      = try c.decodeIfPresent(String.self, forKey: .presetDescription)
        self.presetTags             = try c.decodeIfPresent([String].self, forKey: .presetTags) ?? []
        self.createdAt              = try c.decode(Date.self, forKey: .createdAt)
        self.modifiedAt             = try c.decode(Date.self, forKey: .modifiedAt)
    }

    init(
        id: UUID, name: String, symbol: String, linkedDeviceUID: String?,
        leftEar: EarProfile, rightEar: EarProfile,
        leftNotch: TinnitusNotch, rightNotch: TinnitusNotch, separateNotch: Bool = false,
        dynamics: DynamicProcessingSettings = .init(),
        globalTrimDB: Double, balance: Double = 0, autoEQCurveURL: URL?,
        autoEQName: String? = nil, autoEQBands: [EQBand]? = nil, autoEQPreampDB: Double? = nil,
        autoEQSourcePath: String? = nil,
        safeListeningCeilingDB: Double, compensationFactor: Double,
        separateChannels: Bool = false,
        eqMode: EQMode = .simple,
        isBuiltIn: Bool = false,
        presetDescription: String? = nil,
        presetTags: [String] = [],
        createdAt: Date, modifiedAt: Date
    ) {
        self.id = id; self.name = name; self.symbol = symbol
        self.linkedDeviceUID = linkedDeviceUID
        self.leftEar = leftEar; self.rightEar = rightEar
        self.leftNotch = leftNotch; self.rightNotch = rightNotch
        self.separateNotch = separateNotch
        self.dynamics = dynamics
        self.globalTrimDB = globalTrimDB; self.balance = balance
        self.autoEQCurveURL = autoEQCurveURL
        self.autoEQName = autoEQName
        self.autoEQBands = autoEQBands
        self.autoEQPreampDB = autoEQPreampDB
        self.autoEQSourcePath = autoEQSourcePath
        self.safeListeningCeilingDB = safeListeningCeilingDB
        self.compensationFactor = compensationFactor
        self.separateChannels = separateChannels
        self.eqMode = eqMode
        self.isBuiltIn = isBuiltIn
        self.presetDescription = presetDescription
        self.presetTags = presetTags
        self.createdAt = createdAt; self.modifiedAt = modifiedAt
    }
}

extension HearingProfile {
    /// Returns a copy with a fresh ID, "{name} Copy" name, fresh timestamps,
    /// and `isBuiltIn` cleared. Callers handle name-collision disambiguation
    /// against the store before saving.
    func duplicated() -> HearingProfile {
        var copy = self
        copy.id = UUID()
        copy.name = "\(self.name) Copy"
        // A copy is a user profile, not a factory preset: clear the factory
        // marker and its card metadata so it doesn't show a star badge or a
        // (dead-end) "Reset to Factory Default".
        copy.isBuiltIn = false
        copy.presetDescription = nil
        copy.presetTags = []
        let now = Date()
        copy.createdAt = now
        copy.modifiedAt = now
        return copy
    }

    /// A new, untouched profile. Flat audiogram on both ears, no tinnitus notch,
    /// safe-listening ceiling at the NIOSH-aligned default of 85 dB.
    static func makeDefault(name: String = "Default", symbol: String = "person.fill", isBuiltIn: Bool = false) -> HearingProfile {
        let now = Date()
        return HearingProfile(
            id: UUID(),
            name: name,
            symbol: symbol,
            linkedDeviceUID: nil,
            leftEar: .flat,
            rightEar: .flat,
            leftNotch: .disabled,
            rightNotch: .disabled,
            globalTrimDB: 0,
            autoEQCurveURL: nil,
            safeListeningCeilingDB: 85.0,
            compensationFactor: 0.5,
            isBuiltIn: isBuiltIn,
            createdAt: now,
            modifiedAt: now
        )
    }

}

// MARK: - Factory listening presets

extension HearingProfile {

    /// The four shipped listening-comfort presets, in their canonical UI
    /// order. These are tone/comfort presets built on the existing 10-band
    /// Advanced EQ — explicitly **not** medical hearing correction. Each has
    /// a stable id so "Reset to Factory Default" and "Restore Factory
    /// Presets" can find and rebuild it, and a fixed historical `createdAt`
    /// so the store's createdAt sort places them first, in this order.
    enum Factory: Int, CaseIterable {
        case voiceClarity, musicBalanced, gentleListening, presenceBoost

        var id: UUID {
            switch self {
            case .voiceClarity:    return UUID(uuidString: "F0000001-0000-4000-A000-000000000001")!
            case .musicBalanced:   return UUID(uuidString: "F0000002-0000-4000-A000-000000000002")!
            case .gentleListening: return UUID(uuidString: "F0000003-0000-4000-A000-000000000003")!
            case .presenceBoost:   return UUID(uuidString: "F0000004-0000-4000-A000-000000000004")!
            }
        }

        /// Stable, distant-past timestamp so factory presets sort ahead of
        /// any user profile (created "now") and stay in enum order.
        var createdAt: Date { Date(timeIntervalSince1970: 1_600_000_000 + Double(rawValue)) }
    }

    /// The ten Advanced-EQ center frequencies, in slider order. Mirrors
    /// `AdvancedEQView.frequencies` / `EQMode.advanced` owned slots.
    static let advancedCenters: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    /// Build the ten Advanced parametric bands from a gain-per-center list.
    /// Bandwidth 1.0 (one octave) matches the Advanced graphic-EQ slots so
    /// `AdvancedEQView` finds and shows them via `EQBandLookup`.
    private static func advancedBands(_ gains: [Double]) -> [EQBand] {
        zip(advancedCenters, gains).map { freq, gain in
            EQBand(frequencyHz: freq, gaindB: gain, bandwidth: 1.0, filterType: .parametric, enabled: true)
        }
    }

    private static func makeFactory(
        _ which: Factory, name: String, symbol: String,
        gains: [Double], outputGainDB: Double,
        description: String, tags: [String]
    ) -> HearingProfile {
        let bands = advancedBands(gains)
        let stamp = which.createdAt
        return HearingProfile(
            id: which.id,
            name: name,
            symbol: symbol,
            linkedDeviceUID: nil,
            leftEar: EarProfile(thresholds: AudiogramPoint.flat, bands: bands),
            rightEar: EarProfile(thresholds: AudiogramPoint.flat, bands: bands),
            leftNotch: .disabled,
            rightNotch: .disabled,
            globalTrimDB: outputGainDB,
            autoEQCurveURL: nil,
            safeListeningCeilingDB: 85.0,
            compensationFactor: 0.5,
            eqMode: .advanced,
            isBuiltIn: true,
            presetDescription: description,
            presetTags: tags,
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    static func factoryVoiceClarity() -> HearingProfile {
        makeFactory(.voiceClarity, name: "Voice Clarity", symbol: "waveform.badge.mic",
            gains: [-4, -3, -2, -1, 0, 1, 2, 2.5, 0.5, -1], outputGainDB: -2,
            description: "Improves spoken-word clarity by reducing low-frequency boom and gently increasing speech presence. Best for podcasts, calls, meetings, lectures, and audiobooks.",
            tags: ["Voice", "Speech", "Clarity"])
    }

    static func factoryMusicBalanced() -> HearingProfile {
        makeFactory(.musicBalanced, name: "Music Balanced", symbol: "music.note",
            gains: [0.5, 1, 0.5, -0.5, 0, 0, 0.5, 1, 0, -0.5], outputGainDB: -1,
            description: "A natural, lightly refined music profile with modest bass support and gentle clarity. Designed to preserve the character of music without making it overly bright.",
            tags: ["Music", "Balanced", "Natural"])
    }

    static func factoryGentleListening() -> HearingProfile {
        makeFactory(.gentleListening, name: "Gentle Listening", symbol: "moon.stars",
            gains: [0, 0, 0.5, 0.5, 0, 0, -0.5, -1.5, -2.5, -3], outputGainDB: 0,
            description: "Softens bright or fatiguing audio for longer, more comfortable listening. Useful for sharp headphones, late-night sessions, or content that feels harsh.",
            tags: ["Comfort", "Soft", "Long Sessions"])
    }

    static func factoryPresenceBoost() -> HearingProfile {
        makeFactory(.presenceBoost, name: "Presence Boost", symbol: "sparkles",
            gains: [-1, -1, -1, -0.5, 0, 0.5, 1.5, 2, 0.5, 0], outputGainDB: -2,
            description: "Adds mild definition and presence for audio that sounds dull or veiled. Conservative by design and not a substitute for an audiogram-based profile.",
            tags: ["Clarity", "Presence", "Mild Lift"])
    }

    /// All four factory presets, in canonical UI order.
    static var factoryProfiles: [HearingProfile] {
        [factoryVoiceClarity(), factoryMusicBalanced(), factoryGentleListening(), factoryPresenceBoost()]
    }

    /// The canonical (pristine) factory preset for a given id, or nil if the
    /// id isn't one of the four factory ids. Used to reset an edited factory
    /// profile back to its shipped values.
    static func factoryCanonical(forID id: UUID) -> HearingProfile? {
        factoryProfiles.first { $0.id == id }
    }

    /// The default active profile on a fresh install / after migration.
    static var defaultActiveFactoryID: UUID { Factory.musicBalanced.id }
}

/// Which EQ lens this profile uses. The four modes are storage views
/// onto one underlying band array — picking a mode chooses how the
/// user thinks about EQ for this profile, not how the audio is
/// processed. Switching mode is non-destructive: bands the other
/// modes wrote stay in storage and only hide.
enum EQMode: String, Codable, CaseIterable, Identifiable {
    case simple, speech, advanced, expert

    var id: String { rawValue }

    var label: String {
        switch self {
        case .simple:   return "Simple"
        case .speech:   return "Speech"
        case .advanced: return "Advanced"
        case .expert:   return "Expert"
        }
    }

    var symbol: String {
        switch self {
        case .simple:   return "slider.horizontal.3"
        case .speech:   return "waveform.badge.mic"
        case .advanced: return "slider.vertical.3"
        case .expert:   return "waveform.path"
        }
    }

    var tagline: String {
        switch self {
        case .simple:   return "Three quick knobs — bass, mids, treble."
        case .speech:   return "Six bands tuned for voice intelligibility."
        case .advanced: return "Ten octave-spaced graphic EQ bands."
        case .expert:   return "Full parametric — drop a band anywhere."
        }
    }

    /// (frequency Hz, filter type) pairs the mode owns — bands at
    /// these slots show in the mode's UI. Expert returns nil because
    /// it owns everything; the helper below uses that as a sentinel.
    fileprivate var ownedSlots: Set<EQSlot>? {
        switch self {
        case .simple:
            return [
                EQSlot(frequencyHz: 250,  filterType: .lowShelf),
                EQSlot(frequencyHz: 1000, filterType: .parametric),
                EQSlot(frequencyHz: 5000, filterType: .highShelf),
            ]
        case .speech:
            return [
                EQSlot(frequencyHz: 60,    filterType: .lowShelf),
                EQSlot(frequencyHz: 200,   filterType: .parametric),
                EQSlot(frequencyHz: 800,   filterType: .parametric),
                EQSlot(frequencyHz: 2500,  filterType: .parametric),
                EQSlot(frequencyHz: 6000,  filterType: .parametric),
                EQSlot(frequencyHz: 12000, filterType: .highShelf),
            ]
        case .advanced:
            let centers: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
            return Set(centers.map { EQSlot(frequencyHz: $0, filterType: .parametric) })
        case .expert:
            return nil
        }
    }

    /// Returns the bands in `chain` that aren't visible in this mode's
    /// UI. Expert hides nothing, so always returns []. Non-Expert
    /// modes return any band whose (freq, filterType) doesn't fall in
    /// the owned-slot set.
    func hiddenBands(in chain: [EQBand]) -> [EQBand] {
        guard let owned = ownedSlots else { return [] }
        return chain.filter { band in
            !owned.contains(EQSlot(frequencyHz: band.frequencyHz, filterType: band.filterType))
        }
    }
}

private struct EQSlot: Hashable {
    let frequencyHz: Double
    let filterType: EQFilterType
}
