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
    var isBuiltIn: Bool                         // true for curated presets (Default, Voice Clarity) — UI blocks edits and offers Duplicate

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
        self.safeListeningCeilingDB = try c.decode(Double.self, forKey: .safeListeningCeilingDB)
        self.compensationFactor     = try c.decode(Double.self, forKey: .compensationFactor)
        self.separateChannels       = try c.decodeIfPresent(Bool.self, forKey: .separateChannels) ?? false
        // Legacy profiles default to .expert so users who edited bands
        // across multiple tabs in the old multi-tab world still see
        // everything on first load. New profiles created via init
        // default to .simple — see the designated initializer.
        self.eqMode                 = try c.decodeIfPresent(EQMode.self, forKey: .eqMode) ?? .expert
        self.isBuiltIn              = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
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
        safeListeningCeilingDB: Double, compensationFactor: Double,
        separateChannels: Bool = false,
        eqMode: EQMode = .simple,
        isBuiltIn: Bool = false,
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
        self.safeListeningCeilingDB = safeListeningCeilingDB
        self.compensationFactor = compensationFactor
        self.separateChannels = separateChannels
        self.eqMode = eqMode
        self.isBuiltIn = isBuiltIn
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
        copy.isBuiltIn = false
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

    /// Voice Clarity preset from spec §5.8 — boosts the speech-intelligibility
    /// band cluster (1–6 kHz) for podcast monitoring. Same curve both ears.
    static func makeVoiceClarityPreset() -> HearingProfile {
        let now = Date()
        let curve: [EQBand] = [
            EQBand(frequencyHz: 500,  gaindB: 1, bandwidth: 1.0, filterType: .parametric, enabled: true),
            EQBand(frequencyHz: 1000, gaindB: 2, bandwidth: 1.0, filterType: .parametric, enabled: true),
            EQBand(frequencyHz: 2000, gaindB: 3, bandwidth: 1.0, filterType: .parametric, enabled: true),
            EQBand(frequencyHz: 3000, gaindB: 4, bandwidth: 1.0, filterType: .parametric, enabled: true),
            EQBand(frequencyHz: 4000, gaindB: 3, bandwidth: 1.0, filterType: .parametric, enabled: true),
            EQBand(frequencyHz: 6000, gaindB: 1, bandwidth: 1.0, filterType: .parametric, enabled: true),
        ]
        return HearingProfile(
            id: UUID(),
            name: "Voice Clarity",
            symbol: "waveform.badge.mic",
            linkedDeviceUID: nil,
            leftEar: EarProfile(thresholds: AudiogramPoint.flat, bands: curve),
            rightEar: EarProfile(thresholds: AudiogramPoint.flat, bands: curve),
            leftNotch: .disabled,
            rightNotch: .disabled,
            globalTrimDB: 0,
            autoEQCurveURL: nil,
            safeListeningCeilingDB: 85.0,
            compensationFactor: 0.5,
            isBuiltIn: true,
            createdAt: now,
            modifiedAt: now
        )
    }
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
