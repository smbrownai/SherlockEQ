import Foundation

/// Detect interactions between an active AutoEQ correction and the
/// user's tinnitus notch. AutoEQ profiles sometimes boost near the
/// tinnitus frequency to correct a headphone dip there, which
/// partially counteracts the notch's attenuation. The signal chain
/// still runs as composed — this surface is advisory only.
///
/// The ±1/3 octave window is wide enough to catch a meaningful
/// interaction without flagging every profile (judgment call, see
/// the integration spec's "Design Notes" section). Tunable in one
/// place: `conflictWindowOctaves`.
enum AutoEQConflictDetector {

    /// How far either side of the notch frequency a boosted band has
    /// to fall before we flag it. Spec calls this out as a knob worth
    /// tuning if real-world feedback says warnings fire too often.
    static let conflictWindowOctaves: Double = 1.0 / 3.0

    /// Treated as the "exact-match" tolerance — a band centred within
    /// this many Hz of the notch is treated as a high-severity
    /// conflict regardless of gain.
    static let exactMatchToleranceHz: Double = 1.0

    /// One flagged interaction. The view layer chooses to surface
    /// these as a single banner with a worst-case summary plus a
    /// "Show me" affordance that scrolls to the bands themselves.
    struct Conflict: Hashable {
        let band: EQBand
        let isExactMatch: Bool
    }

    /// Returns every AutoEQ band whose centre frequency lies within
    /// the conflict window of `notchFrequency` AND is boosting (gain
    /// > 0). Disabled bands are skipped.
    static func detect(
        autoEQBands: [EQBand],
        notchFrequency: Double
    ) -> [Conflict] {
        guard notchFrequency > 0 else { return [] }
        let lowerBound = notchFrequency * pow(2.0, -conflictWindowOctaves)
        let upperBound = notchFrequency * pow(2.0,  conflictWindowOctaves)

        var conflicts: [Conflict] = []
        for band in autoEQBands where band.enabled && band.gaindB > 0 {
            guard band.frequencyHz >= lowerBound, band.frequencyHz <= upperBound else { continue }
            let isExact = abs(band.frequencyHz - notchFrequency) <= exactMatchToleranceHz
            conflicts.append(Conflict(band: band, isExactMatch: isExact))
        }
        return conflicts
    }

    /// Convenience: detect against a hearing profile's active AutoEQ
    /// bands using the profile's L notch if enabled, R notch
    /// otherwise. Returns an empty list if neither notch is on or
    /// the profile has no AutoEQ correction loaded.
    static func detect(in profile: HearingProfile) -> [Conflict] {
        guard let bands = profile.autoEQBands, !bands.isEmpty else { return [] }
        let frequencies: [Double] = {
            var fs: [Double] = []
            if profile.leftNotch.enabled { fs.append(profile.leftNotch.frequencyHz) }
            if profile.rightNotch.enabled, profile.rightNotch.frequencyHz != profile.leftNotch.frequencyHz {
                fs.append(profile.rightNotch.frequencyHz)
            }
            return fs
        }()
        guard !frequencies.isEmpty else { return [] }
        var seen = Set<Conflict>()
        for f in frequencies {
            for c in detect(autoEQBands: bands, notchFrequency: f) {
                seen.insert(c)
            }
        }
        return Array(seen)
    }
}
