import Foundation

/// Width of the tinnitus notch filter. Maps to a Q value when realized as a
/// biquad band (`narrow ~ Q 8`, `medium ~ Q 4`, `wide ~ Q 2`) per the spec.
enum NotchWidth: String, Codable, CaseIterable {
    case narrow
    case medium
    case wide

    var qValue: Double {
        switch self {
        case .narrow: return 8.0
        case .medium: return 4.0
        case .wide: return 2.0
        }
    }

    /// Equivalent −3 dB bandwidth in octaves (Audio EQ Cookbook formula).
    /// Surfaced in the UI so "Narrow / Medium / Wide" isn't opaque — the
    /// user can see the real span of audio the notch touches. Note these
    /// are genuinely narrow: Q 8 ≈ 0.18 oct, Q 4 ≈ 0.36 oct, Q 2 ≈ 0.72 oct.
    var approxOctaves: Double {
        guard qValue > 0 else { return 0 }
        return (2.0 / log(2.0)) * asinh(1.0 / (2.0 * qValue))
    }

    /// Compact transparency string, e.g. "Q 4 · ≈ 0.36 octave".
    var detail: String {
        String(format: "Q %.0f · ≈ %.2f octave", qValue, approxOctaves)
    }

    var label: String {
        switch self {
        case .narrow: return "Narrow"
        case .medium: return "Medium"
        case .wide:   return "Wide"
        }
    }
}

/// Comfort-oriented strength presets for the tinnitus notch. Each maps to a
/// (width, depth) pair; the sliders remain the advanced override. Framed
/// around listening comfort vs. fidelity, not "how hard to fight the ringing"
/// — a deeper/wider notch trades more clarity for more reduction.
enum NotchPreset: String, CaseIterable, Identifiable {
    case subtle
    case balanced
    case strong

    var id: String { rawValue }

    var label: String {
        switch self {
        case .subtle:   return "Subtle"
        case .balanced: return "Balanced"
        case .strong:   return "Strong"
        }
    }

    var width: NotchWidth {
        switch self {
        case .subtle:   return .narrow
        case .balanced: return .medium
        case .strong:   return .wide
        }
    }

    var depthdB: Double {
        switch self {
        case .subtle:   return -4
        case .balanced: return -6
        case .strong:   return -12
        }
    }

    /// One-line description of the perceptual trade-off.
    var blurb: String {
        switch self {
        case .subtle:   return "Keeps audio clearest — a gentle dip at the pitch."
        case .balanced: return "Noticeable softening while preserving most detail."
        case .strong:   return "Stronger reduction; may sound duller or muffled."
        }
    }
}

/// Configuration for the per-profile tinnitus notch filter.
struct TinnitusNotch: Codable, Hashable {
    var enabled: Bool
    var frequencyHz: Double       // typically 1000–16000
    var depthdB: Double           // negative — typically -3 to -15
    var qWidth: NotchWidth
}

extension TinnitusNotch {
    /// Sensible default: disabled, mid-range placeholder until the user runs Tone Finder.
    static var disabled: TinnitusNotch {
        TinnitusNotch(
            enabled: false,
            frequencyHz: 4000,
            depthdB: -6,
            qWidth: .medium
        )
    }

    /// The strength preset whose (width, depth) matches the current settings,
    /// or `nil` when the user has dialled in a custom combination. Depth is
    /// matched within 0.5 dB so slider quantisation doesn't read as "Custom".
    var preset: NotchPreset? {
        NotchPreset.allCases.first {
            $0.width == qWidth && abs($0.depthdB - depthdB) < 0.5
        }
    }

    /// Apply a strength preset's width + depth, leaving frequency and the
    /// enabled flag untouched (the pitch and on/off are the user's; presets
    /// only shape the comfort/fidelity trade-off).
    mutating func apply(_ preset: NotchPreset) {
        qWidth = preset.width
        depthdB = preset.depthdB
    }

    /// The EQ band this notch realises — the single source of truth for both
    /// the audio path (`SherlockEQAudioEngine`) and every curve renderer
    /// (`ParametricCanvasView`, `NotchPreviewView`), so what the user sees
    /// and hears can't diverge. Returns nil when disabled.
    ///
    /// It is a *peaking* filter (`.parametric`) with negative gain — a finite,
    /// depth-controllable dip — deliberately NOT a pure RBJ `.notch`. The RBJ
    /// notch ignores gain (always an infinite null) and its `bandwidth` was
    /// being passed as `1/Q`, so the old Depth control did nothing and the
    /// Narrow/Wide labels were inverted. A parametric cut honours `depthdB`
    /// exactly at center and takes `qWidth.qValue` as Q directly, so Narrow
    /// (Q 8) is genuinely narrower than Wide (Q 2).
    func asEQBand() -> EQBand? {
        guard enabled else { return nil }
        return EQBand(
            frequencyHz: frequencyHz,
            gaindB: depthdB,
            bandwidth: qWidth.qValue,
            filterType: .parametric,
            enabled: true
        )
    }
}
