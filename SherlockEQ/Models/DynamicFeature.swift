import Foundation

/// Level-dependent ("dynamic") EQ processors for hearing-comfort use
/// cases. Unlike the static per-ear `BiquadCascade`, a dynamic feature
/// only engages its bell while the triggering content is actually
/// present — a sibilance cut that dulls every "s" without dulling the
/// vowels between them, a presence boost that lifts dialogue but relaxes
/// during the score.
///
/// `DynamicFeatureKind` carries ALL of the per-feature DSP constants
/// (the spec §2 table) as static metadata. Tuning is therefore a
/// one-file change — same convention as `conflictWindowOctaves` in the
/// AutoEQ work. Keeping the constants on the *kind* (not on the
/// persisted `DynamicFeatureSettings`) means the profile JSON records
/// only what the user chose — enabled / strength / sensitivity — and
/// never the tuning, so a later tuning pass doesn't have to migrate
/// stored data.
///
/// These are deliberately NOT modelled as `EQBand`s: storing them as
/// bands would entangle them with `EQMode.ownedSlots`, `HiddenBandsHintChip`
/// accounting, preset menus, AutoEQ combine logic, and
/// `audiblyEquivalent(to:)` — none of which know what a threshold or an
/// attack time means. They follow the Tinnitus Notch pattern instead:
/// dedicated fields on `HearingProfile`, folded into the audio path at
/// `applyProfile` time, with their own panel.
enum DynamicFeatureKind: String, Codable, CaseIterable, Identifiable {
    case speechPresence
    case harshnessControl
    case sibilanceTamer

    var id: String { rawValue }

    // MARK: - Display metadata

    var displayName: String {
        switch self {
        case .speechPresence:   return "Speech Presence"
        case .harshnessControl: return "Harshness Control"
        case .sibilanceTamer:   return "Sibilance Tamer"
        }
    }

    var symbol: String {
        switch self {
        case .speechPresence:   return "person.wave.2"
        case .harshnessControl: return "speaker.wave.2.bubble"
        case .sibilanceTamer:   return "waveform.path.ecg"
        }
    }

    /// One plain-language sentence pair for the Clarity card. Speaks to a
    /// non-engineer: what it listens for, what it does, how the two
    /// sliders behave.
    var helpText: String {
        switch self {
        case .speechPresence:
            return "Listens for talking and gently lifts voices so dialogue stays clear over music or ambience. Raise Strength for a stronger lift; raise Sensitivity to react to quieter speech."
        case .harshnessControl:
            return "Listens for shouty, compressed midrange energy and eases it only while it's present. Raise Strength for a deeper cut; raise Sensitivity to react sooner."
        case .sibilanceTamer:
            return "Listens for sharp \u{201C}sss\u{201D} energy and softens it only while it's present. Raise Strength for a deeper cut; raise Sensitivity to react to quieter sibilance."
        }
    }

    // MARK: - Detector (sidechain)

    enum DetectorType { case rms, peak }

    /// Sidechain band-pass corners (Hz). A constant-skirt band-pass runs
    /// over the post-static-EQ input; its peak or RMS energy drives the
    /// adaptive threshold and envelope.
    var detectorBand: (lowHz: Double, highHz: Double) {
        switch self {
        case .speechPresence:   return (1_500, 4_000)
        case .harshnessControl: return (2_000, 5_000)
        case .sibilanceTamer:   return (5_000, 9_000)
        }
    }

    var detectorType: DetectorType {
        switch self {
        case .speechPresence:   return .rms
        case .harshnessControl: return .rms
        case .sibilanceTamer:   return .peak
        }
    }

    // MARK: - Main filter (the bell whose gain is modulated)

    var filterCenterHz: Double {
        switch self {
        case .speechPresence:   return 2_500
        case .harshnessControl: return 3_500
        case .sibilanceTamer:   return 6_500
        }
    }

    var filterQ: Double {
        switch self {
        case .speechPresence:   return 0.9
        case .harshnessControl: return 1.4
        case .sibilanceTamer:   return 2.0
        }
    }

    // MARK: - Ballistics

    var attackMs: Double {
        switch self {
        case .speechPresence:   return 30
        case .harshnessControl: return 10
        case .sibilanceTamer:   return 3
        }
    }

    var releaseMs: Double {
        switch self {
        case .speechPresence:   return 300
        case .harshnessControl: return 150
        case .sibilanceTamer:   return 80
        }
    }

    /// Compression (cut features) or gating (boost feature) ratio applied
    /// to the overshoot above the soft knee.
    var ratio: Double {
        switch self {
        case .speechPresence:   return 2.0   // gated boost engage
        case .harshnessControl: return 2.0
        case .sibilanceTamer:   return 3.0
        }
    }

    /// Soft-knee width in dB, centred on the adaptive threshold.
    var kneeDB: Double { 6.0 }

    // MARK: - Gain & sensitivity ranges

    /// Sign-carrying maximum gain delta at Strength = 1.0 (dB). Cut
    /// features are negative; Speech Presence is the only positive
    /// (boosting) feature, capped at +6 dB so the downstream AUPeakLimiter
    /// stays the absolute ceiling.
    var maxDeltaDB: Double {
        switch self {
        case .speechPresence:   return  6
        case .harshnessControl: return -8
        case .sibilanceTamer:   return -10
        }
    }

    /// The Sensitivity slider maps (inverted) into this offset-above-
    /// rolling-average range, in dB.
    var sensitivityRangeDB: (min: Double, max: Double) { (3, 15) }

    /// Whether the feature boosts or cuts — derived from the sign of
    /// `maxDeltaDB`. Used by the gain computer and the UI activity meter.
    enum Direction { case boost, cut }
    var direction: Direction { maxDeltaDB >= 0 ? .boost : .cut }

    // MARK: - Slider → DSP mappings

    /// Strength 0…1 → sign-carrying max gain delta (dB), linear.
    /// e.g. Sibilance at strength 1.0 → −10 dB; at 0.5 → −5 dB.
    func maxDeltaDB(strength: Double) -> Double {
        let s = min(1, max(0, strength))
        return maxDeltaDB * s
    }

    /// Sensitivity 0…1 → threshold offset above the rolling average (dB).
    /// Inverted: sensitivity 0 → +15 dB (triggers rarely), 1 → +3 dB
    /// (triggers readily).
    func thresholdOffsetDB(sensitivity: Double) -> Double {
        let s = min(1, max(0, sensitivity))
        let (lo, hi) = sensitivityRangeDB
        return hi + (lo - hi) * s
    }
}

/// Per-feature, per-ear user choices. The only dynamic-processing data
/// that persists in the profile JSON. Tuning constants live on
/// `DynamicFeatureKind`, never here.
struct DynamicFeatureSettings: Codable, Equatable, Hashable {
    var enabled: Bool = false
    /// 0…1 → scales the feature's max gain delta.
    var strength: Double = 0.5
    /// 0…1 → maps onto the feature's offset range (inverted: higher
    /// sensitivity = lower offset = triggers sooner).
    var sensitivity: Double = 0.5
}

/// The full dynamic-processing block on a `HearingProfile`. Six
/// independent feature settings (3 kinds × 2 ears) plus a Separate-L/R
/// flag that mirrors `separateNotch` / `separateChannels` semantics.
struct DynamicProcessingSettings: Codable, Equatable, Hashable {
    var leftSpeechPresence:  DynamicFeatureSettings = .init()
    var rightSpeechPresence: DynamicFeatureSettings = .init()
    var leftHarshness:       DynamicFeatureSettings = .init()
    var rightHarshness:      DynamicFeatureSettings = .init()
    var leftSibilance:       DynamicFeatureSettings = .init()
    var rightSibilance:      DynamicFeatureSettings = .init()

    /// Mirrors `separateNotch`: when false the Clarity panel shows one
    /// shared card per feature and every edit writes both ears; when true
    /// it shows stacked per-ear cards.
    var separateChannels: Bool = false

    // MARK: - Keyed access (so UI and engine never switch over six fields)

    /// Read the settings for one (kind, ear). A computed read so callers
    /// stay declarative; the matching setter mutates the backing field.
    func settings(for kind: DynamicFeatureKind, ear: EQBandLookup.Ear) -> DynamicFeatureSettings {
        switch (kind, ear) {
        case (.speechPresence, .left):   return leftSpeechPresence
        case (.speechPresence, .right):  return rightSpeechPresence
        case (.harshnessControl, .left): return leftHarshness
        case (.harshnessControl, .right):return rightHarshness
        case (.sibilanceTamer, .left):   return leftSibilance
        case (.sibilanceTamer, .right):  return rightSibilance
        }
    }

    mutating func setSettings(_ value: DynamicFeatureSettings, for kind: DynamicFeatureKind, ear: EQBandLookup.Ear) {
        switch (kind, ear) {
        case (.speechPresence, .left):   leftSpeechPresence = value
        case (.speechPresence, .right):  rightSpeechPresence = value
        case (.harshnessControl, .left): leftHarshness = value
        case (.harshnessControl, .right):rightHarshness = value
        case (.sibilanceTamer, .left):   leftSibilance = value
        case (.sibilanceTamer, .right):  rightSibilance = value
        }
    }

    /// True if any feature is enabled on either ear — drives the
    /// Expert-canvas Dynamics chip's hidden/shown state and the
    /// applyProfile debug summary.
    var hasAnyEnabled: Bool {
        [leftSpeechPresence, rightSpeechPresence,
         leftHarshness, rightHarshness,
         leftSibilance, rightSibilance].contains { $0.enabled }
    }
}
