import Foundation

/// The outcome-named preset curves (phase3-make-correction-land.md §3.2) —
/// ONE table serving both surfaces that offer presets:
///   • the Graphic EQ's purpose-preset selector, and
///   • the factory listening profiles (§3.3), which wrap four of these.
/// Single source of truth so the selector and the factory cards can't
/// drift apart; tuning a curve is a one-place change.
///
/// Curves are named for the listening *outcome* the user wants, not a
/// genre or a skill level — a small, evidence-derived starting set (see
/// spec §1.6), voiced on the 12-band audiometric grid with excursions
/// large enough to be clearly audible on a Reference-Mode A/B (≥ 2 dB
/// coordinated moves) while staying comfort-preset-tasteful. These are
/// tone/comfort shapes, NOT hearing correction — the audiogram-derived
/// NAL-R layer is separate and stacks with them.
enum PresetCurve: String, CaseIterable, Identifiable {
    case flat
    case clearerVoices
    case musicBalance
    case gentleListening
    case reduceBoom
    case reduceHarshness

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flat:            return "Flat"
        case .clearerVoices:   return "Clearer voices"
        case .musicBalance:    return "Music balance"
        case .gentleListening: return "Gentle listening"
        case .reduceBoom:      return "Reduce boom"
        case .reduceHarshness: return "Reduce harshness"
        }
    }

    var symbol: String {
        switch self {
        case .flat:            return "minus"
        case .clearerVoices:   return "waveform.badge.mic"
        case .musicBalance:    return "music.note"
        case .gentleListening: return "moon.stars"
        case .reduceBoom:      return "speaker.minus"
        case .reduceHarshness: return "ear.trianglebadge.exclamationmark"
        }
    }

    var tagline: String {
        switch self {
        case .flat:            return "All sliders to zero — the unprocessed baseline."
        case .clearerVoices:   return "Speech presence and consonant detail up, low rumble down."
        case .musicBalance:    return "Light warmth, less mud, gentle clarity — the everyday shape."
        case .gentleListening: return "Progressively softens the highs for long, comfortable sessions."
        case .reduceBoom:      return "Tightens a boomy low end so voices and detail come through."
        case .reduceHarshness: return "Eases the shouty 2–5 kHz region that makes audio tiring."
        }
    }

    /// Gains in dB, positionally aligned with `EQMode.graphicCenters`
    /// (31.5 / 63 / 125 / 250 / 500 / 1k / 2k / 3k / 4k / 6k / 8k / 16k Hz).
    var gains: [Double] {
        switch self {
        case .flat:            return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .clearerVoices:   return [-4, -3, -2, -1, 0, 0.9, 2.9, 5.4, 2, -1]
        case .musicBalance:    return [1.5, 2, 1, -0.5, -0.5, -0.1, 1.6, 2.9, 1, 0]
        case .gentleListening: return [0, 0, 0.5, 0.5, 0, 0, -0.8, -3.9, -5.2, -4.4]
        case .reduceBoom:      return [-3, -2.5, -2, -1.5, -0.5, 0, 0.7, 0.3, 0, 0]
        case .reduceHarshness: return [0, 0, 0, 0, 0, -0.4, -2.4, -4.7, -1.7, -0.5]
        }
    }

    /// Output trim applied alongside the gains — headroom against clipping
    /// for curves that boost. Part of the curve's design, so both the
    /// selector and the factory profiles apply it.
    var trimDB: Double {
        switch self {
        case .clearerVoices: return -2
        case .musicBalance:  return -1
        case .flat, .gentleListening, .reduceBoom, .reduceHarshness: return 0
        }
    }

    /// The curve as graphic-slot bands (one-octave parametric bells on the
    /// 12-band grid). Zero-gain slots are still emitted so applying a curve
    /// deterministically overwrites every slider.
    var bands: [EQBand] {
        zip(EQMode.graphicCenters, gains).map { freq, gain in
            EQBand(frequencyHz: freq, gaindB: gain, bandwidth: 1.0, filterType: .parametric, enabled: true)
        }
    }

    // MARK: - Selection detection

    /// Slider values within this tolerance of a curve's read as that curve —
    /// half the Graphic slider's finest (0.1 dB) step, so drag rounding
    /// can't flip the selector to "Custom".
    static let matchToleranceDB: Double = 0.05

    /// The curve the given per-ear slider gains + trim currently represent,
    /// or nil ("Custom") when they match none. Both ears must match — a
    /// per-ear divergence is a custom state by definition.
    static func matching(
        leftGains: [Double], rightGains: [Double], trimDB: Double
    ) -> PresetCurve? {
        allCases.first { curve in
            abs(trimDB - curve.trimDB) <= matchToleranceDB
                && matches(curve.gains, leftGains)
                && matches(curve.gains, rightGains)
        }
    }

    private static func matches(_ a: [Double], _ b: [Double]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= matchToleranceDB }
    }
}
