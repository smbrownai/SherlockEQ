import Foundation

/// One day's subjective tinnitus-annoyance rating.
///
/// Deliberately **not** a validated clinical instrument — there is no TFI/THI
/// scoring here, and the UI never claims one. It's a simple 0–10 "how much did
/// it bother you today" so the user can eyeball whether things trend better or
/// worse over time while they experiment with the notch and their listening
/// habits. Separating perceived loudness from annoyance/distress is itself a
/// useful framing (annoyance is what sound therapy and habituation target).
struct TinnitusCheckIn: Codable, Identifiable, Equatable {
    /// Local start-of-day the rating covers. Serves as identity — one rating
    /// per calendar day (a later rating for the same day replaces the earlier).
    let dayStart: Date
    /// 0 (not at all) … 10 (extremely bothersome). Whole numbers.
    let annoyance: Int

    var id: Date { dayStart }
}
