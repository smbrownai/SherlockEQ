import Foundation
import Combine
import OSLog

/// NIOSH-based listening-dose accumulator (spec §5.4, §7.5).
///
/// - Permissible duration at any A-weighted level uses the NIOSH equal-energy
///   rule: 28800 s ÷ 2^((dBA − 85) / 3).
/// - Each level sample adds `elapsed / permissibleDuration` to the cumulative
///   dose, where 1.0 = 100 % of daily safe limit.
/// - Levels < `quietThresholdDBA` don't accumulate. A sustained quiet period
///   resets the dose (spec default: 2 hours).
@MainActor
final class SafeListeningTracker: ObservableObject {

    /// 0…1. 1.0 means "at safe daily limit"; bar goes red in the UI.
    @Published private(set) var sessionDose: Double = 0
    /// Estimate of how many more minutes are safe at the current level.
    /// `nil` when below quietThreshold (effectively unlimited).
    @Published private(set) var remainingMinutes: Double?
    /// Most recently observed A-weighted level (dBA estimate from the analyzer).
    @Published private(set) var currentLevelDBA: Double = 0

    /// True once dose crossed 80 % today (reset at midnight or manual reset).
    /// Drives the amber menu-bar icon tint + first warning notification.
    @Published private(set) var didCrossAmberToday: Bool = false
    /// True once dose hit 100 % today. Drives the red icon tint + final
    /// "take a break" notification.
    @Published private(set) var didCrossRedToday: Bool = false

    /// Reset after this much sustained quiet (default 2 hours, per spec).
    var quietResetDuration: TimeInterval = 2 * 3600
    /// Below this, we consider the user not listening — controls the
    /// quiet-period reset and the "remaining minutes" display only. Dose
    /// itself accumulates at all levels (NIOSH math is self-regulating —
    /// permissible duration at e.g. 30 dBA is days, contribution is ~0).
    var quietThresholdDBA: Double = 50

    static let nioshReferenceLevelDBA: Double = 85
    static let nioshReferenceDuration: TimeInterval = 8 * 3600   // 28 800 s
    static let nioshExchangeRateDB: Double = 3

    private var lastUpdateTime: Date?
    private var quietStartTime: Date?
    private var currentResetDay: Date = Calendar.current.startOfDay(for: Date())
    private let log = Logger(subsystem: "com.shawnbrown.AuditumEQ", category: "SafeListening")

    /// Permissible exposure duration in seconds at a given dBA level.
    static func permissibleDuration(at dBA: Double) -> TimeInterval {
        nioshReferenceDuration / pow(
            2.0,
            (dBA - nioshReferenceLevelDBA) / nioshExchangeRateDB
        )
    }

    /// Feed the next level sample. Call rate ~10 Hz is plenty; we self-time
    /// against the wall clock for resilience to irregular cadence.
    func update(levelDBA: Double) {
        let now = Date()
        let elapsed = lastUpdateTime.map { now.timeIntervalSince($0) } ?? 0
        lastUpdateTime = now

        // Midnight rollover.
        let today = Calendar.current.startOfDay(for: now)
        if today != currentResetDay {
            resetDose(reason: "midnight rollover")
            currentResetDay = today
        }

        let priorDose = sessionDose

        // Clamp to a sane range — runaway calibration or near-silent rooms
        // can otherwise produce nonsense values that distort the math.
        let clamped = min(140, max(0, levelDBA))
        currentLevelDBA = clamped

        // Sustained-quiet detection — only resets dose if we stay below threshold
        // for `quietResetDuration` continuously. Doesn't gate dose accumulation.
        if clamped < quietThresholdDBA {
            if quietStartTime == nil { quietStartTime = now }
            else if let start = quietStartTime,
                    now.timeIntervalSince(start) > quietResetDuration {
                resetDose(reason: "sustained quiet")
            }
        } else {
            quietStartTime = nil
        }

        // Accumulate dose at all levels — the NIOSH math is self-regulating
        // (permissible duration at low dBA is huge, contribution near zero).
        let chunk = min(5.0, max(0, elapsed))
        if chunk > 0 {
            let perm = Self.permissibleDuration(at: clamped)
            if perm.isFinite, perm > 0 {
                sessionDose = min(1.0, sessionDose + chunk / perm)
            }
        }

        // Remaining minutes only meaningful when we're at a listening level.
        if clamped >= quietThresholdDBA {
            let permNow = Self.permissibleDuration(at: clamped)
            if permNow.isFinite, permNow > 0 {
                let remainingSeconds = (1.0 - sessionDose) * permNow
                remainingMinutes = max(0, remainingSeconds / 60)
            } else {
                remainingMinutes = nil
            }
        } else {
            remainingMinutes = nil   // effectively unlimited / not listening
        }

        // Threshold crossings → notifications (only fire once per day).
        if !didCrossAmberToday, priorDose < 0.8, sessionDose >= 0.8 {
            didCrossAmberToday = true
            log.info("Crossed 80% dose threshold")
            NotificationManager.shared.send(
                title: "Approaching your safe listening limit",
                body: "You've used 80% of your recommended daily exposure. Consider turning the volume down."
            )
        }
        if !didCrossRedToday, priorDose < 1.0, sessionDose >= 1.0 {
            didCrossRedToday = true
            log.info("Reached 100% dose threshold")
            NotificationManager.shared.send(
                title: "Safe listening limit reached",
                body: "You've reached your safe listening limit for today. Consider taking a break."
            )
        }
    }

    /// Debug helper: jam the dose to a specific value, triggering any
    /// crossings on the way. Used by the Debug section to verify the
    /// menu-bar icon tint and notifications without waiting hours.
    func forceForTesting(dose: Double) {
        let target = max(0, min(1, dose))
        let prior = sessionDose
        sessionDose = target
        if !didCrossAmberToday, prior < 0.8, target >= 0.8 {
            didCrossAmberToday = true
            NotificationManager.shared.send(
                title: "Approaching your safe listening limit",
                body: "You've used 80% of your recommended daily exposure. Consider turning the volume down."
            )
        }
        if !didCrossRedToday, prior < 1.0, target >= 1.0 {
            didCrossRedToday = true
            NotificationManager.shared.send(
                title: "Safe listening limit reached",
                body: "You've reached your safe listening limit for today. Consider taking a break."
            )
        }
    }

    /// Manual reset (user action or midnight rollover, spec §5.4).
    func resetDose(reason: String = "manual") {
        if sessionDose > 0 {
            log.info("Dose reset (\(reason, privacy: .public)) from \(self.sessionDose, format: .fixed(precision: 2))")
        }
        sessionDose = 0
        quietStartTime = nil
        didCrossAmberToday = false
        didCrossRedToday = false
    }
}
