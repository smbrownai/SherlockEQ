import Foundation

/// The acclimatization ramp (phase3-make-correction-land.md §5): a newly
/// applied hearing correction starts at 60 % strength and rises linearly to
/// 100 % over 21 days.
///
/// Why: NAL-R already prescribes ~⅓ of the loss because full restoration is
/// intolerable to an unaccustomed ear — and the old 0.5 default strength was
/// a *permanent* workaround for that first-week harshness, leaving long-term
/// users at ~0.155·HTL forever. The ramp is the honest version of the same
/// instinct: gentle entry, full prescription once the ear has adapted —
/// mirroring real-world hearing-aid fitting practice.
///
/// Pure date math, no state — the single source of truth consumed by the
/// audio engine and every drawing surface via
/// `HearingProfile.effectiveCorrectionBands(now:)` (Design note 1:
/// drawn = heard, always).
enum AcclimatizationRamp {

    /// Strength fraction on day zero.
    static let startFraction: Double = 0.6
    /// Days from stamp to full strength.
    static let durationDays: Double = 21

    /// Multiplier on the correction's target strength. `nil` start (legacy
    /// profiles, or ramp skipped/completed-and-cleared) → 1.0. A start date
    /// in the future (clock rolled back) clamps to the day-zero fraction
    /// rather than extrapolating below it.
    static func factor(start: Date?, now: Date = Date()) -> Double {
        guard let start else { return 1.0 }
        let days = now.timeIntervalSince(start) / 86_400
        guard days > 0 else { return startFraction }
        guard days < durationDays else { return 1.0 }
        return startFraction + (1.0 - startFraction) * (days / durationDays)
    }

    /// True while the ramp is still shy of full strength.
    static func isRamping(start: Date?, now: Date = Date()) -> Bool {
        factor(start: start, now: now) < 1.0
    }

    /// 1-based day number for the UI ("day N of 21"), clamped to the ramp.
    static func dayNumber(start: Date, now: Date = Date()) -> Int {
        let days = Int(now.timeIntervalSince(start) / 86_400) + 1
        return min(max(days, 1), Int(durationDays))
    }
}
