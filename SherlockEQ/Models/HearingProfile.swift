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
    var autoEQName: String?                     // display label for the loaded AutoEQ correction
    var autoEQBands: [EQBand]?                  // parsed AutoEQ bands; applied per-ear upstream of profile EQ
    var autoEQPreampDB: Double?                 // headroom adjustment baked into the AutoEQ file
    /// AutoEQ catalog `path` the correction was applied from, if any. Stored so
    /// the saved-profiles UI can identify "this entry is the one applied" by an
    /// unambiguous key — the catalog has duplicate display names across
    /// source/type (e.g. the same model from oratory1990 and Crinacle), so a
    /// name match alone can point at the wrong correction. decodeIfPresent.
    var autoEQSourcePath: String?
    /// Output device the correction was attached on (UID + display name),
    /// recorded at attach time. Drives the device-mismatch warning
    /// (phase3-make-correction-land.md §7): a correction is voiced for one
    /// specific transducer, so running it on a different output deserves a
    /// heads-up. Nil on legacy profiles (attached before this field
    /// existed) — no warning until re-attached; no fuzzy name matching.
    var autoEQDeviceUID: String?
    var autoEQDeviceName: String?
    var safeListeningCeilingDB: Double          // user-set, default 85.0
    /// Target correction strength (0.25–1.0), applied at CONSUMPTION time:
    /// `correctionBands` store the FULL NAL-R prescription and every
    /// consumer (engine + previews) reads `effectiveCorrectionBands(now:)`,
    /// which scales gains by `compensationFactor × AcclimatizationRamp`.
    /// (Previously the factor was baked in at derivation time — which left
    /// the strength sliders writing a value nothing re-derived from: a
    /// silent no-op. Consumption-time scaling fixes that structurally.)
    var compensationFactor: Double              // 0.25–1.0 — audiogram→EQ strength
    /// When the profile's FIRST audiogram was applied — starts the 21-day
    /// 60→100 % acclimatization ramp (phase3 §5). Nil = no ramp (legacy
    /// profiles, or the user hit "Skip to full strength"). Ongoing
    /// audiogram edits deliberately do NOT restamp.
    var acclimatizationStartDate: Date?
    /// Where this profile's audiogram came from — shown on the Audiogram
    /// screen so provenance is never ambiguous ("From Listening Check,
    /// Jul 15 2026"). decodeIfPresent; legacy profiles read `.manual`.
    var audiogramSource: AudiogramSource
    /// When the audiogram was last applied/edited (any source). Nil until
    /// the profile first carries one.
    var audiogramDate: Date?
    /// When true, EQ tabs show per-ear sliders; when false, every edit
    /// applies to both ears in lockstep. Lives on the profile because
    /// the audiogram itself is per-ear — symmetric-hearing users keep
    /// this off and avoid a row of duplicate sliders; asymmetric-
    /// hearing users flip it on per-profile without a global setting.
    /// Toggling the value never mutates band data; only future edits
    /// in the new mode propagate to one or both ears.
    var separateChannels: Bool                  // default false — single column UI
    /// Which EQ surface this profile uses — Graphic (12-band audiometric
    /// graphic EQ) or Parametric (full canvas). Both edit the same band
    /// array; switching is non-destructive, and Graphic surfaces any
    /// bands it can't edit via its "Other filters" row instead of hiding
    /// them. See `EQMode`.
    var eqMode: EQMode                          // new profiles default .advanced (Graphic); legacy decode .expert
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
        self.autoEQName             = try c.decodeIfPresent(String.self, forKey: .autoEQName)
        self.autoEQBands            = try c.decodeIfPresent([EQBand].self, forKey: .autoEQBands)
        self.autoEQPreampDB         = try c.decodeIfPresent(Double.self, forKey: .autoEQPreampDB)
        self.autoEQSourcePath       = try c.decodeIfPresent(String.self, forKey: .autoEQSourcePath)
        self.autoEQDeviceUID        = try c.decodeIfPresent(String.self, forKey: .autoEQDeviceUID)
        self.autoEQDeviceName       = try c.decodeIfPresent(String.self, forKey: .autoEQDeviceName)
        self.safeListeningCeilingDB = try c.decode(Double.self, forKey: .safeListeningCeilingDB)
        self.compensationFactor     = try c.decode(Double.self, forKey: .compensationFactor)
        self.acclimatizationStartDate = try c.decodeIfPresent(Date.self, forKey: .acclimatizationStartDate)
        self.audiogramSource        = try c.decodeIfPresent(AudiogramSource.self, forKey: .audiogramSource) ?? .manual
        self.audiogramDate          = try c.decodeIfPresent(Date.self, forKey: .audiogramDate)
        self.separateChannels       = try c.decodeIfPresent(Bool.self, forKey: .separateChannels) ?? false
        // Legacy profiles default to .expert so users who edited bands
        // across multiple tabs in the old multi-tab world still see
        // everything on first load. New profiles created via init
        // default to .advanced (Graphic) — see the designated initializer.
        self.eqMode                 = try c.decodeIfPresent(EQMode.self, forKey: .eqMode) ?? .expert
        self.isBuiltIn              = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        self.presetDescription      = try c.decodeIfPresent(String.self, forKey: .presetDescription)
        self.presetTags             = try c.decodeIfPresent([String].self, forKey: .presetTags) ?? []
        self.createdAt              = try c.decode(Date.self, forKey: .createdAt)
        self.modifiedAt             = try c.decode(Date.self, forKey: .modifiedAt)

        // Backfill the audiogram correction layer for profiles whose audiogram
        // predates it (correctionBands empty but thresholds carry loss), or
        // whose derived bands were deleted out of `bands`. Derive from the
        // stored thresholds and strip any baked-in correction from `bands` so
        // it can't apply twice. Flat / zero-compensation audiograms derive to
        // all-disabled bands and are skipped, so normal hearing stays inert.
        Self.backfillCorrection(&self.leftEar)
        Self.backfillCorrection(&self.rightEar)
        // Normalize legacy corrections to full strength: profiles written
        // before consumption-time scaling stored bands with the (then-
        // current) compensationFactor baked in. correctionBands are pure
        // derived data — always recomputable from thresholds — so re-derive
        // at 1.0. Idempotent for profiles already stored at full strength.
        Self.normalizeCorrectionToFullStrength(&self.leftEar)
        Self.normalizeCorrectionToFullStrength(&self.rightEar)
    }

    /// Populate `ear.correctionBands` from its thresholds when the layer is
    /// empty (legacy profile or deleted bands). No-op once populated, so it's
    /// idempotent across loads. See [[audiogram-correction-layer]].
    private static func backfillCorrection(_ ear: inout EarProfile) {
        guard ear.correctionBands.isEmpty else { return }
        let derived = AudiogramConversion.bands(for: ear.thresholds, compensationFactor: 1.0)
        guard derived.contains(where: { $0.enabled }) else { return }
        ear.correctionBands = derived
        ear.bands = EQBandLookup.removingAudiogramBands(matching: derived, from: ear.bands)
    }

    /// Re-derive a populated correction layer at full strength. Replaces
    /// only `correctionBands` (never touches `bands` — the legacy
    /// bands-stripping belongs to the empty-layer backfill above, and
    /// repeating it could eat user-authored bands at audiogram slots).
    /// Conservative when thresholds are flat but a correction exists
    /// (shouldn't happen; leave the stored layer alone rather than guess).
    private static func normalizeCorrectionToFullStrength(_ ear: inout EarProfile) {
        guard !ear.correctionBands.isEmpty else { return }
        let derived = AudiogramConversion.bands(for: ear.thresholds, compensationFactor: 1.0)
        guard derived.contains(where: { $0.enabled }) else { return }
        ear.correctionBands = derived
    }

    /// The applied strength right now: the user's target
    /// (`compensationFactor`) × the acclimatization ramp.
    func effectiveCorrectionStrength(now: Date = Date()) -> Double {
        compensationFactor * AcclimatizationRamp.factor(start: acclimatizationStartDate, now: now)
    }

    /// The correction the listener should actually get right now — the
    /// stored full-strength prescription scaled by
    /// `effectiveCorrectionStrength`. THE single source of truth (spec
    /// Design note 1): the audio engine, the audiogram preview, and both
    /// EQ canvases all consume this, so drawn always equals heard. Scaling
    /// realised band gains is equivalent to re-deriving at the effective
    /// strength within the overlap-fit's linearity (≲0.2 dB).
    func effectiveCorrectionBands(now: Date = Date()) -> (left: [EQBand], right: [EQBand]) {
        let strength = effectiveCorrectionStrength(now: now)
        guard strength < 1.0 else { return (leftEar.correctionBands, rightEar.correctionBands) }
        func scaled(_ bands: [EQBand]) -> [EQBand] {
            bands.map { band in
                var copy = band
                copy.gaindB *= strength
                return copy
            }
        }
        return (scaled(leftEar.correctionBands), scaled(rightEar.correctionBands))
    }

    /// True while the acclimatization ramp is still short of full strength.
    func isAcclimatizing(now: Date = Date()) -> Bool {
        AcclimatizationRamp.isRamping(start: acclimatizationStartDate, now: now)
    }

    /// Call after (re)writing thresholds + correction. The FIRST time an
    /// audiogram populates this profile (no prior correction on either
    /// ear), start at the full prescription with the ramp providing the
    /// gentle entry: target strength 1.0, stamp now. Ongoing audiogram
    /// edits keep the user's strength and the running ramp — retuning one
    /// threshold mid-ramp must not restart the clock or override a chosen
    /// strength.
    mutating func startAcclimatizationIfFirstAudiogram(
        hadCorrectionBefore: Bool, now: Date = Date()
    ) {
        guard !hadCorrectionBefore,
              !leftEar.correctionBands.isEmpty || !rightEar.correctionBands.isEmpty
        else { return }
        compensationFactor = 1.0
        acclimatizationStartDate = now
    }

    init(
        id: UUID, name: String, symbol: String, linkedDeviceUID: String?,
        leftEar: EarProfile, rightEar: EarProfile,
        leftNotch: TinnitusNotch, rightNotch: TinnitusNotch, separateNotch: Bool = false,
        dynamics: DynamicProcessingSettings = .init(),
        globalTrimDB: Double, balance: Double = 0,
        autoEQName: String? = nil, autoEQBands: [EQBand]? = nil, autoEQPreampDB: Double? = nil,
        autoEQSourcePath: String? = nil,
        autoEQDeviceUID: String? = nil, autoEQDeviceName: String? = nil,
        safeListeningCeilingDB: Double, compensationFactor: Double,
        acclimatizationStartDate: Date? = nil,
        audiogramSource: AudiogramSource = .manual,
        audiogramDate: Date? = nil,
        separateChannels: Bool = false,
        eqMode: EQMode = .advanced,
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
        self.autoEQName = autoEQName
        self.autoEQBands = autoEQBands
        self.autoEQPreampDB = autoEQPreampDB
        self.autoEQSourcePath = autoEQSourcePath
        self.autoEQDeviceUID = autoEQDeviceUID
        self.autoEQDeviceName = autoEQDeviceName
        self.safeListeningCeilingDB = safeListeningCeilingDB
        self.compensationFactor = compensationFactor
        self.acclimatizationStartDate = acclimatizationStartDate
        self.audiogramSource = audiogramSource
        self.audiogramDate = audiogramDate
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
    /// order. Each wraps one shared `PresetCurve` (§3.2's single source of
    /// truth) — explicitly **not** medical hearing correction. Each has
    /// a stable id so "Reset to Factory Default" and "Restore Factory
    /// Presets" can find and rebuild it, and a fixed historical `createdAt`
    /// so the store's createdAt sort places them first, in this order.
    ///
    /// v2 note (phase3-make-correction-land.md §3.3): Presence Boost
    /// (F0000004…) was retired — it was Voice Clarity at ~60 % scale — and
    /// replaced by Reduce Boom with a NEW id. `ProfileStore`'s reconcile
    /// deletes an unedited Presence Boost and demotes an edited one to a
    /// user profile; its id must never be reused.
    enum Factory: Int, CaseIterable {
        case voiceClarity, musicBalanced, gentleListening, reduceBoom

        var id: UUID {
            switch self {
            case .voiceClarity:    return UUID(uuidString: "F0000001-0000-4000-A000-000000000001")!
            case .musicBalanced:   return UUID(uuidString: "F0000002-0000-4000-A000-000000000002")!
            case .gentleListening: return UUID(uuidString: "F0000003-0000-4000-A000-000000000003")!
            case .reduceBoom:      return UUID(uuidString: "F0000005-0000-4000-A000-000000000005")!
            }
        }

        /// Stable, distant-past timestamp so factory presets sort ahead of
        /// any user profile (created "now") and stay in enum order.
        var createdAt: Date { Date(timeIntervalSince1970: 1_600_000_000 + Double(rawValue)) }
    }

    private static func makeFactory(
        _ which: Factory, name: String, symbol: String,
        curve: PresetCurve,
        description: String, tags: [String]
    ) -> HearingProfile {
        let bands = curve.bands
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
            globalTrimDB: curve.trimDB,
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
            curve: .clearerVoices,
            description: "Voices are hard to follow — lifts speech presence and consonant detail while easing low-frequency boom. For podcasts, calls, TV dialogue, and audiobooks.",
            tags: ["Voice", "Speech", "Clarity"])
    }

    static func factoryMusicBalanced() -> HearingProfile {
        makeFactory(.musicBalanced, name: "Music Balanced", symbol: "music.note",
            curve: .musicBalance,
            description: "The everyday starting point — light warmth, less low-mid mud, and a gentle clarity lift. Audible against Reference Mode without imposing a strong flavor.",
            tags: ["Music", "Everyday", "Balanced"])
    }

    static func factoryGentleListening() -> HearingProfile {
        makeFactory(.gentleListening, name: "Gentle Listening", symbol: "moon.stars",
            curve: .gentleListening,
            description: "Audio feels sharp or tiring — progressively softens the highs for long, comfortable sessions, sharp headphones, and late-night listening.",
            tags: ["Comfort", "Soft", "Long Sessions"])
    }

    static func factoryReduceBoom() -> HearingProfile {
        makeFactory(.reduceBoom, name: "Reduce Boom", symbol: "speaker.minus",
            curve: .reduceBoom,
            description: "Audio sounds boomy or muddy — tightens the low end so voices and detail come through. Good for boomy rooms, small speakers, and bass-heavy headphones.",
            tags: ["Clarity", "Low End", "Small Speakers"])
    }

    /// All four factory presets, in canonical UI order.
    static var factoryProfiles: [HearingProfile] {
        [factoryVoiceClarity(), factoryMusicBalanced(), factoryGentleListening(), factoryReduceBoom()]
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

/// Which EQ surface this profile uses. Two surfaces, named for the tool
/// rather than the user's skill level (phase3-make-correction-land.md §1):
/// **Graphic** (12-band audiometric graphic EQ) and **Parametric** (the
/// full canvas — arbitrary frequency, gain, Q, and filter type; a
/// materially different editing model, not "more sliders").
///
/// Persisted raw values remain `"advanced"` / `"expert"` so existing
/// profile JSON, exports, and imports round-trip unchanged; only display
/// names changed. The retired v1 modes ("simple", "speech") decode onto
/// Graphic — their bands stay in storage and surface through Graphic's
/// "Other filters" row rather than running invisibly.
enum EQMode: String, Codable, CaseIterable, Identifiable {
    case advanced   // display name: Graphic
    case expert     // display name: Parametric

    /// Tolerant decode: retired mode strings (and anything unknown) map
    /// to Graphic. Encoding stays the synthesized rawValue, so a migrated
    /// profile re-saves as `"advanced"`.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EQMode(rawValue: raw) ?? .advanced
    }

    /// The Advanced (Graphic) surface's slider centers — the 12-band
    /// audiometric grid (phase3-make-correction-land.md §2). The octave
    /// series plus 3 kHz and 6 kHz: audiogram frequencies where
    /// presbycusis concentrates and consonant energy lives, previously
    /// missing from the graphic surface. Single source of truth — the
    /// slider row (`GraphicEQView.frequencies`) and this mode's
    /// `ownedSlots` both read it, so the surface and the hidden-bands
    /// accounting can't drift apart.
    static let graphicCenters: [Double] = [
        31.5, 63, 125, 250, 500, 1000, 2000, 3000, 4000, 6000, 8000, 16000
    ]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .advanced: return "Graphic"
        case .expert:   return "Parametric"
        }
    }

    var symbol: String {
        switch self {
        case .advanced: return "slider.vertical.3"
        case .expert:   return "waveform.path"
        }
    }

    var tagline: String {
        switch self {
        case .advanced: return "Twelve graphic bands on the audiometric grid."
        case .expert:   return "Full parametric — drop a band anywhere."
        }
    }

    /// (frequency Hz, filter type) pairs the surface owns — bands at
    /// these slots show on its sliders. Parametric returns nil because
    /// it owns everything; the helper below uses that as a sentinel.
    fileprivate var ownedSlots: Set<EQSlot>? {
        switch self {
        case .advanced:
            return Set(Self.graphicCenters.map { EQSlot(frequencyHz: $0, filterType: .parametric) })
        case .expert:
            return nil
        }
    }

    /// Returns the bands in `chain` that aren't on this surface's own
    /// controls. Parametric hides nothing, so always returns []. Graphic
    /// returns any band whose (freq, filterType) doesn't fall in the
    /// owned-slot set — these drive the "Other filters" row, which offers
    /// conversion or the Parametric escape hatch so nothing active is
    /// ever invisible.
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

/// How a profile's audiogram was entered. Drives the provenance line on the
/// Audiogram screen — an in-app Listening Check estimate is framed
/// differently from a typed-in clinical audiogram (phase3 §4.5).
enum AudiogramSource: String, Codable {
    case manual
    case listeningCheck
    case imported

    var label: String {
        switch self {
        case .manual:         return "manual entry"
        case .listeningCheck: return "Listening Check"
        case .imported:       return "imported file"
        }
    }
}

extension HearingProfile {
    /// Apply a measured/entered audiogram: store thresholds, derive the
    /// full-strength correction (strength applies at consumption time,
    /// phase3 §5), strip legacy baked-in correction from `bands`, record
    /// provenance, and start the acclimatization ramp on first
    /// application. One shared path for the Listening Check and the
    /// interchange import so the two can't drift.
    mutating func applyMeasuredAudiogram(
        left: [AudiogramPoint], right: [AudiogramPoint],
        source: AudiogramSource, now: Date = Date()
    ) {
        let hadCorrectionBefore = !leftEar.correctionBands.isEmpty
            || !rightEar.correctionBands.isEmpty
        leftEar.thresholds = left
        rightEar.thresholds = right
        for ear in [\HearingProfile.leftEar, \HearingProfile.rightEar] {
            let derived = AudiogramConversion.bands(
                for: self[keyPath: ear].thresholds,
                compensationFactor: 1.0
            )
            self[keyPath: ear].correctionBands = derived
            self[keyPath: ear].bands = EQBandLookup.removingAudiogramBands(
                matching: derived,
                from: self[keyPath: ear].bands
            )
        }
        audiogramSource = source
        audiogramDate = now
        startAcclimatizationIfFirstAudiogram(hadCorrectionBefore: hadCorrectionBefore, now: now)
    }
}
