import Foundation

/// One calendar day's listening-dose summary, captured at the day boundary.
///
/// `peakDose` is the highest NIOSH dose fraction (0…1) reached that day — the
/// safety-relevant figure. The live `SafeListeningTracker.sessionDose` is the
/// *current* accumulated dose, which gets zeroed by both the midnight rollover
/// and a sustained-quiet reset, so it can't be sampled at midnight to learn
/// what the day's exposure actually was. The tracker therefore keeps a separate
/// running peak and hands it here when the day finalizes.
struct DailyDoseRecord: Codable, Identifiable, Equatable {
    /// Local start-of-day (midnight) the record covers. Serves as identity.
    let dayStart: Date
    /// Peak dose fraction reached that day (0…1, 1.0 = NIOSH daily limit).
    let peakDose: Double

    var id: Date { dayStart }

    /// Spec §5.4 severity band for the day, derived from the peak so the
    /// chart colours match the live dose card's 80 % / 100 % thresholds.
    var severity: SafeListeningTracker.DoseSeverity {
        if peakDose >= 1.0 { return .red }
        if peakDose >= 0.8 { return .amber }
        return .safe
    }
}
