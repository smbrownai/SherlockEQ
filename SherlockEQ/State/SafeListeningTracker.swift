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
    /// Highest `sessionDose` reached since the last midnight rollover. Unlike
    /// `sessionDose` (which a sustained-quiet period or manual reset zeroes
    /// mid-day), this is the day's high-water mark — the figure the 7-day
    /// history records when the day finalizes. The Safe Listening chart reads
    /// it for "today" (no store record exists for today until midnight).
    @Published private(set) var peakDoseToday: Double = 0
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
    @Published var quietResetDuration: TimeInterval = 2 * 3600
    /// Below this, we consider the user not listening — controls the
    /// quiet-period reset and the "remaining minutes" display only. Dose
    /// itself accumulates at all levels (NIOSH math is self-regulating —
    /// permissible duration at e.g. 30 dBA is days, contribution is ~0).
    @Published var quietThresholdDBA: Double = 50
    /// User-facing kill switch for the 80/100 % notifications.
    @Published var notificationsEnabled: Bool = true

    static let nioshReferenceLevelDBA: Double = 85
    static let nioshReferenceDuration: TimeInterval = 8 * 3600   // 28 800 s
    static let nioshExchangeRateDB: Double = 3

    private var lastUpdateTime: Date?
    private var quietStartTime: Date?
    private var currentResetDay: Date = Calendar.current.startOfDay(for: Date())
    private let log = Logger(subsystem: "com.shawnbrown.SherlockEQ", category: "SafeListening")

    /// Power-domain rolling average of A-weighted level over the last
    /// ~minute (linear units, 10^(dBA/10)). Used to estimate "remaining
    /// time" off a stable equivalent-continuous level rather than the
    /// instantaneous reading, which would otherwise twitch every audio
    /// sample. NIOSH math is logarithmic, so averaging must be done in
    /// power-domain — arithmetic averaging of dBA is wrong by ~3 dB per
    /// 6 dB of peak-to-mean.
    private var avgPower: Double = 0
    /// Time constant for the level average. ~60 s reaches 63 % of a
    /// step; 3·τ = 180 s reaches 95 %. Slow enough that brief peaks
    /// don't distort the estimate but fast enough that a real volume
    /// change is reflected within a couple of minutes.
    private let averagingTau: TimeInterval = 60
    /// Wall-clock timestamp of the last `remainingMinutes` republish.
    /// `nil` until the first valid estimate has been emitted.
    private var lastEstimatePublish: Date?
    /// How often we let the public `remainingMinutes` value change.
    /// Once per minute so the user reads a stable number, not a
    /// per-sample jitter.
    private let estimatePublishInterval: TimeInterval = 60

    /// Largest inter-sample interval still treated as continuous listening.
    /// Dose samples arrive at ~20 Hz (every ~50 ms) while audio renders; a gap
    /// longer than this means audio paused, the Mac slept, or the analysis
    /// pipeline stalled, so we don't credit the whole unobserved span as
    /// exposure. (The old fixed 5 s cap credited up to 5 s of a pause at the
    /// resumed — possibly loud — level.) ~1 s tolerates scheduling jitter while
    /// keeping the accumulation honest.
    private let maxIntegrationStep: TimeInterval = 1.0

    // MARK: - Persistence (daily dose survives relaunch within the same day)

    private let defaults = UserDefaults.standard
    private enum DefaultsKey {
        static let dose = "sherlockeq.dose.sessionDose"
        static let peak = "sherlockeq.dose.peakDose"
        static let crossedAmber = "sherlockeq.dose.crossedAmber"
        static let crossedRed = "sherlockeq.dose.crossedRed"
        /// Legacy: local-midnight as an absolute epoch. Re-interpreting it via
        /// `startOfDay` in a different time zone could shift the day, so the
        /// day identity is now `dayKey` (below). Still read as a migration
        /// fallback for installs that persisted before the switch.
        static let resetDayEpoch = "sherlockeq.dose.resetDayEpoch"
        /// Time-zone-stable calendar-day identity ("yyyy-MM-dd") of the current
        /// dose day. Comparing day keys (not epochs) makes same-day detection
        /// and the closed-across-midnight recovery correct when the user changes
        /// time zone between sessions.
        static let dayKey = "sherlockeq.dose.dayKey"
    }

    /// Time-zone-stable "yyyy-MM-dd" key for the local calendar day containing
    /// `date`. Derived from `Calendar.current` components so it captures the
    /// day the user actually listened, independent of any later time-zone move.
    /// Internal (not private) so the day-identity round-trip can be unit-tested.
    static func dayKey(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Inverse of `dayKey(for:)` — the local start-of-day for a "yyyy-MM-dd"
    /// key. `DoseHistoryStore.record` re-normalises via `startOfDay`, so this
    /// only needs to land anywhere inside that calendar day.
    static func date(fromDayKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        return Calendar.current.date(from: comps)
    }
    /// Only true once `beginDailyTracking()` runs (the real app at launch).
    /// Gates restore + persist so unit tests that construct a bare tracker
    /// stay pristine and never read or write the shared defaults domain
    /// (which hosted tests share with production — see memory note).
    private var trackingActive = false

    /// Invoked when a calendar day finalizes — at the midnight rollover while
    /// running, or at launch when the app was closed across midnight. Receives
    /// the finished day's start-of-day and its peak dose (0…1). `AudioState`
    /// wires this to `DoseHistoryStore.record(dayStart:peakDose:)`. Left nil in
    /// unit tests (a bare tracker), so they never write the history file.
    var onDayFinalized: ((Date, Double) -> Void)?
    /// Throttle for the periodic dose write; crossings + resets persist eagerly.
    private var lastPersist: Date?
    private let persistInterval: TimeInterval = 15
    /// Fires ~once a minute so the day rolls over even with no audio playing.
    private var rolloverTimer: Timer?

    deinit { rolloverTimer?.invalidate() }

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

        // Midnight rollover (also driven by `rolloverTimer` when no audio plays).
        checkDayRollover(now: now)

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
        // Cap the credited interval to one integration step so an unobserved
        // gap (pause / sleep / stall) isn't booked as exposure (see
        // `maxIntegrationStep`).
        let chunk = min(maxIntegrationStep, max(0, elapsed))
        if chunk > 0 {
            let perm = Self.permissibleDuration(at: clamped)
            if perm.isFinite, perm > 0 {
                sessionDose = min(1.0, sessionDose + chunk / perm)
            }
        }

        // Track the day's high-water mark for the 7-day history. Climbs only;
        // sustained-quiet / manual resets leave it (the day's exposure already
        // happened), and the midnight rollover clears it after recording.
        if sessionDose > peakDoseToday { peakDoseToday = sessionDose }

        // Power-domain rolling average of A-weighted level. Update on
        // every sample so the average stays current; we still gate the
        // PUBLISH of the user-visible `remainingMinutes` to a 60 s
        // cadence below.
        if clamped > 0 {
            let powerNow = pow(10.0, clamped / 10.0)
            if avgPower == 0 {
                avgPower = powerNow
            } else if elapsed > 0 {
                let alpha = 1.0 - exp(-elapsed / averagingTau)
                avgPower += (powerNow - avgPower) * alpha
            }
        }

        // Below threshold → "not listening." Surface immediately rather
        // than waiting for the 60 s republish boundary; the user
        // expects the readout to disappear as soon as they pause.
        if clamped < quietThresholdDBA {
            remainingMinutes = nil
            lastEstimatePublish = nil
        } else {
            // At a listening level. Recompute the estimate either on
            // the first sample of a new listening burst or after a
            // full publish interval has elapsed.
            let shouldPublish: Bool = {
                guard let last = lastEstimatePublish else { return true }
                return now.timeIntervalSince(last) >= estimatePublishInterval
            }()
            if shouldPublish, avgPower > 0 {
                let avgDBA = 10 * log10(avgPower)
                let permAvg = Self.permissibleDuration(at: avgDBA)
                if permAvg.isFinite, permAvg > 0 {
                    let remainingSeconds = (1.0 - sessionDose) * permAvg
                    remainingMinutes = max(0, remainingSeconds / 60)
                } else {
                    remainingMinutes = nil
                }
                lastEstimatePublish = now
            }
        }

        // Threshold crossings → notifications (only fire once per day).
        if !didCrossAmberToday, priorDose < 0.8, sessionDose >= 0.8 {
            didCrossAmberToday = true
            log.info("Crossed 80% dose threshold")
            persistState()   // eager: a crossing is the state we most want to survive a crash
            if notificationsEnabled {
                NotificationManager.shared.send(
                    title: "Approaching your safe listening limit",
                    body: "You've used 80% of your recommended daily exposure. Consider turning the volume down."
                )
            }
        }
        if !didCrossRedToday, priorDose < 1.0, sessionDose >= 1.0 {
            didCrossRedToday = true
            log.info("Reached 100% dose threshold")
            persistState()
            if notificationsEnabled {
                NotificationManager.shared.send(
                    title: "Safe listening limit reached",
                    body: "You've reached your safe listening limit for today. Consider taking a break."
                )
            }
        }

        // Persist periodically so a relaunch within the same day resumes the
        // accumulated dose instead of restarting from zero. No-op until
        // `beginDailyTracking()` has run (i.e. only in the real app).
        if trackingActive,
           lastPersist == nil || now.timeIntervalSince(lastPersist!) >= persistInterval {
            persistState()
        }
    }

    /// Debug helper: jam the dose to a specific value, triggering any
    /// crossings on the way. Used by the Debug section to verify the
    /// menu-bar icon tint and notifications without waiting hours.
    func forceForTesting(dose: Double) {
        let target = max(0, min(1, dose))
        let prior = sessionDose
        sessionDose = target
        if sessionDose > peakDoseToday { peakDoseToday = sessionDose }
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
        // Clear the rolling-level state too so the next listening
        // burst gets a fresh estimate rather than carrying the prior
        // session's average across a break.
        avgPower = 0
        lastEstimatePublish = nil
        remainingMinutes = nil
        persistState()   // record the zeroed state so a relaunch doesn't restore stale dose
    }

    // MARK: - Daily lifecycle + persistence

    /// Called once by `AudioState` at app launch (NOT from `init`, so unit
    /// tests that construct a bare tracker stay pristine). Restores today's
    /// accumulated dose from the previous run and starts the midnight-rollover
    /// timer so the day rolls over even when no audio is playing.
    func beginDailyTracking() {
        guard !trackingActive else { return }
        trackingActive = true
        restoreState()
        startRolloverTimer()
    }

    /// Roll the daily counters over when the calendar day changes. Driven both
    /// by incoming level samples (`update`) and by `rolloverTimer`, so the reset
    /// happens even with no audio across midnight. `currentResetDay` is advanced
    /// *before* `resetDose` so the persisted state carries the new day.
    private func checkDayRollover(now: Date = Date()) {
        let today = Calendar.current.startOfDay(for: now)
        guard today != currentResetDay else { return }
        // Record the day that's ending (its peak, not the current dose, which a
        // late-evening quiet period may already have zeroed) before resetting.
        finalizeDay(dayStart: currentResetDay, peak: peakDoseToday)
        currentResetDay = today
        peakDoseToday = 0
        resetDose(reason: "midnight rollover")
    }

    /// Hand a finished day's peak to whoever's listening (the history store, in
    /// the real app). Days with no exposure aren't reported — an absent record
    /// reads as "no listening" in the chart, not "zero dose".
    private func finalizeDay(dayStart: Date, peak: Double) {
        guard peak > 0 else { return }
        onDayFinalized?(dayStart, peak)
    }

    private func startRolloverTimer() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkDayRollover() }
        }
        // .common so it still fires during UI tracking/menu interaction.
        RunLoop.main.add(timer, forMode: .common)
        rolloverTimer = timer
    }

    private func restoreState() {
        // Resolve the persisted day as a time-zone-stable key. Prefer the new
        // `dayKey`; fall back to deriving one from the legacy epoch for installs
        // that persisted before the switch (one-time migration).
        let storedDayKey: String
        if let key = defaults.string(forKey: DefaultsKey.dayKey) {
            storedDayKey = key
        } else if let epoch = defaults.object(forKey: DefaultsKey.resetDayEpoch) as? Double {
            storedDayKey = Self.dayKey(for: Date(timeIntervalSince1970: epoch))
        } else {
            return  // nothing persisted yet
        }

        // The persisted peak is newer than the day's `dose` (which a quiet
        // period may have zeroed); fall back to `dose` for installs that
        // predate the peak key.
        let storedPeak = min(1.0, max(0, (defaults.object(forKey: DefaultsKey.peak) as? Double)
            ?? defaults.double(forKey: DefaultsKey.dose)))

        guard storedDayKey == Self.dayKey(for: currentResetDay) else {
            // Persisted state belongs to a previous calendar day — the app was
            // closed across midnight (or the user changed time zone). Bank that
            // day's peak into history before the daily counters start fresh.
            if let bankedDay = Self.date(fromDayKey: storedDayKey) {
                finalizeDay(dayStart: bankedDay, peak: storedPeak)
            }
            clearPersistedState()
            return
        }
        sessionDose = min(1.0, max(0, defaults.double(forKey: DefaultsKey.dose)))
        peakDoseToday = max(storedPeak, sessionDose)
        didCrossAmberToday = defaults.bool(forKey: DefaultsKey.crossedAmber)
        didCrossRedToday = defaults.bool(forKey: DefaultsKey.crossedRed)
        if sessionDose > 0 {
            log.info("Restored today's dose: \(self.sessionDose, format: .fixed(precision: 2))")
        }
    }

    private func persistState() {
        guard trackingActive else { return }
        defaults.set(sessionDose, forKey: DefaultsKey.dose)
        defaults.set(peakDoseToday, forKey: DefaultsKey.peak)
        defaults.set(didCrossAmberToday, forKey: DefaultsKey.crossedAmber)
        defaults.set(didCrossRedToday, forKey: DefaultsKey.crossedRed)
        defaults.set(Self.dayKey(for: currentResetDay), forKey: DefaultsKey.dayKey)
        lastPersist = Date()
    }

    private func clearPersistedState() {
        defaults.removeObject(forKey: DefaultsKey.dose)
        defaults.removeObject(forKey: DefaultsKey.peak)
        defaults.removeObject(forKey: DefaultsKey.crossedAmber)
        defaults.removeObject(forKey: DefaultsKey.crossedRed)
        defaults.removeObject(forKey: DefaultsKey.dayKey)
        defaults.removeObject(forKey: DefaultsKey.resetDayEpoch)  // legacy
    }

    /// Spec §5.4 dose tinting band. Single source of truth for any UI
    /// that wants to colour-code dose state — menu-bar icon, popover,
    /// Safe Listening view, Monitor sidebar all consume this so the
    /// thresholds can't drift apart between surfaces. The `didCross*`
    /// flags make severity monotone within a day: once the user has
    /// hit a band, it sticks even if they go quiet enough that the
    /// instantaneous dose dips below the threshold.
    enum DoseSeverity {
        case safe   // below 80 %
        case amber  // ≥ 80 % or didCrossAmberToday
        case red    // ≥ 100 % or didCrossRedToday
    }

    var doseSeverity: DoseSeverity {
        if didCrossRedToday || sessionDose >= 1.0 { return .red }
        if didCrossAmberToday || sessionDose >= 0.8 { return .amber }
        return .safe
    }
}
