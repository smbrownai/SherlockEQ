import Foundation

/// The Listening Check's procedure engine (phase3-make-correction-land.md §4):
/// a **modified Hughson–Westlake** ascending-threshold estimate at the 8
/// audiogram frequencies, per ear — the same staircase an audiologist runs,
/// minus the calibrated booth.
///
/// Pure state machine: no audio, no timers, no randomness of its own (catch
/// scheduling is injected). The UI presents `phase`'s trial, collects one
/// boolean (heard / not heard within the response window), and feeds it back
/// through `respond(heard:)`. Every rule is therefore unit-testable without
/// an audio engine.
///
/// Naming discipline: this is a **Listening Check** producing an *estimate*.
/// It is not a hearing test and diagnoses nothing; results feed the same
/// audiogram → NAL-R path as manual entry, with the anchor uncertainty
/// disclosed (Design note 4).
struct ListeningCheckSession {

    enum TestEar: String, Equatable {
        case left = "Left"
        case right = "Right"
    }

    // MARK: - Procedure constants

    /// Test order: 1 kHz first (most recognizable), high frequencies where
    /// presbycusis lives, then the lows, then a 1 kHz retest as the
    /// reliability check — clinical convention.
    static let frequencySequence: [Double] = [1000, 2000, 3000, 4000, 6000, 8000, 500, 250]
    static let retestFrequency: Double = 1000

    /// Modified Hughson–Westlake: descend 10 dB after every response,
    /// ascend 5 dB after every miss.
    static let stepDownDB: Double = 10
    static let stepUpDB: Double = 5
    /// Threshold rule: lowest level responded to in ≥ 2 ascending arrivals.
    static let ascendingHitsRequired = 2
    /// Familiarization starts at this estimated hearing level.
    static let familiarizationStartHL: Double = 40
    /// Next frequency starts this far above the previous threshold.
    static let startAboveThresholdDB: Double = 15
    /// Two misses at the safety ceiling → the frequency is unmeasurable;
    /// we never chase a threshold above the ceiling.
    static let ceilingMissesForUnmeasurable = 2
    /// Runaway guard per frequency (pathological response patterns).
    static let maxTrialsPerFrequency = 35
    /// 1 kHz retest differing from the first run by more than this flags
    /// the ear low-reliability (never silently averaged — spec open-Q6).
    static let retestToleranceDB: Double = 10
    /// False alarms (responses during silent catch trials) above this per
    /// ear flag low reliability.
    static let falseAlarmLimit = 2

    /// RETSPL — dB SPL at 0 dB HL for a generic supra-aural headphone
    /// (ANSI S3.6-derived, TDH-39 family). One fixed table: the absolute
    /// anchor already carries ±5–10 dB of disclosed uncertainty through the
    /// user's SPL calibration, so per-model RETSPL would be false precision.
    static let retspl: [Double: Double] = [
        250: 26.5, 500: 13.5, 1000: 7.5, 2000: 9.0,
        3000: 10.0, 4000: 9.5, 6000: 15.5, 8000: 13.0,
    ]

    // MARK: - Configuration

    struct Config {
        /// Hard safety cap on presentation level (spec §4.2):
        /// `min(−25 dBFS, 80 dBA − effectiveCalibrationOffsetDBA)`.
        var ceilingDBFS: Double
        /// Quietest presentable level.
        var floorDBFS: Double = -85
        /// dBFS → dB SPL anchor (the Phase-1 volume-anchored calibration).
        var effectiveCalibrationOffsetDBA: Double
        /// Probability of inserting a silent catch trial before a real one.
        var catchRate: Double = 0.15

        static func safetyCeilingDBFS(effectiveCalibrationOffsetDBA: Double) -> Double {
            min(-25, 80 - effectiveCalibrationOffsetDBA)
        }
    }

    // MARK: - Trial / results types

    struct Trial: Equatable {
        var ear: TestEar
        var frequencyHz: Double
        /// Presentation level. Meaningless for catch trials (silence).
        var levelDBFS: Double
        var isCatch: Bool
        var isFamiliarization: Bool
    }

    struct FrequencyResult: Equatable {
        var frequencyHz: Double
        /// nil = unmeasurable at the safety ceiling (excluded from NAL-R;
        /// the results screen shows the professional-help caveat).
        var thresholdDBFS: Double?
    }

    struct EarResult: Equatable {
        var ear: TestEar
        var frequencyResults: [FrequencyResult] = []
        var falseAlarms: Int = 0
        /// Retest-minus-first 1 kHz threshold, when both were measurable.
        var retestDeltaDB: Double?
        /// Familiarization failed even at the ceiling — the ear couldn't
        /// be tested at all.
        var aborted: Bool = false
        /// A frequency hit the runaway trial cap.
        var hitTrialCap: Bool = false

        var lowReliability: Bool {
            aborted || hitTrialCap
                || falseAlarms > ListeningCheckSession.falseAlarmLimit
                || (retestDeltaDB.map { abs($0) > ListeningCheckSession.retestToleranceDB } ?? false)
        }
    }

    enum Phase: Equatable {
        case idle
        case presenting(Trial)
        /// First ear finished; UI shows the between-ears interstitial and
        /// calls `continueToNextEar()`.
        case earComplete(TestEar)
        case finished
    }

    // MARK: - Public state

    private(set) var phase: Phase = .idle
    private(set) var completedEars: [EarResult] = []
    let config: Config
    /// Injected catch scheduling — deterministic in tests, random in the app.
    var catchDecider: () -> Bool

    /// Rough progress for the UI: fraction of (ears × frequencies incl.
    /// retest) whose staircase has concluded.
    var progress: Double {
        let perEar = Double(Self.frequencySequence.count + 1)
        let done = Double(completedEars.count) * perEar + Double(working.frequencyResults.count)
        return min(1, done / (perEar * 2))
    }

    init(config: Config, catchDecider: @escaping () -> Bool = { Double.random(in: 0..<1) < 0.15 }) {
        self.config = config
        self.catchDecider = catchDecider
    }

    // MARK: - Working state (private)

    private var earOrder: [TestEar] = [.left, .right]
    private var working = EarResult(ear: .left)
    /// Index into `frequencySequence`; `== count` means the 1 kHz retest.
    private var freqIndex = 0
    private var isRetest: Bool { freqIndex == Self.frequencySequence.count }
    private var currentFrequency: Double {
        isRetest ? Self.retestFrequency : Self.frequencySequence[freqIndex]
    }

    private enum Mode { case familiarization, descending, ascending }
    private var mode: Mode = .familiarization
    private var level: Double = 0
    /// Ascending arrivals and hits per level (dB values are grid-aligned:
    /// start ± multiples of 5, so exact-key matching is safe).
    private var ascendingHits: [Double: Int] = [:]
    private var ceilingMisses = 0
    private var trialsThisFrequency = 0
    private var lastWasCatch = false

    // MARK: - dBFS ↔ dB HL

    /// `estimatedDBHL(f) = (dBFS + effectiveCalibrationOffsetDBA) − RETSPL(f)`
    func dbHL(fromDBFS dbfs: Double, at hz: Double) -> Double {
        (dbfs + config.effectiveCalibrationOffsetDBA) - (Self.retspl[hz] ?? 0)
    }

    func dbFS(fromHL hl: Double, at hz: Double) -> Double {
        hl + (Self.retspl[hz] ?? 0) - config.effectiveCalibrationOffsetDBA
    }

    private func clampLevel(_ dbfs: Double) -> Double {
        min(config.ceilingDBFS, max(config.floorDBFS, dbfs))
    }

    // MARK: - Events

    /// Start the check. `firstEar` is the ear the user says hears better
    /// (clinical convention: test the better ear first); default left.
    mutating func begin(firstEar: TestEar = .left) {
        earOrder = firstEar == .right ? [.right, .left] : [.left, .right]
        completedEars = []
        startEar(earOrder[0])
    }

    /// Feed one trial outcome: `heard` when the user responded inside the
    /// window, false when the window expired.
    mutating func respond(heard: Bool) {
        guard case .presenting(let trial) = phase else { return }

        if trial.isCatch {
            if heard { working.falseAlarms += 1 }
            lastWasCatch = true
            presentNext()
            return
        }
        lastWasCatch = false

        switch mode {
        case .familiarization:
            if heard {
                // Familiar — begin the real staircase one step down.
                mode = .descending
                level = clampLevel(level - Self.stepDownDB)
            } else if level >= config.ceilingDBFS {
                // At the ceiling already. Give the same two-miss tolerance
                // as the staircase (a blink shouldn't abort the ear), but
                // never push louder than the safety cap.
                ceilingMisses += 1
                if ceilingMisses >= Self.ceilingMissesForUnmeasurable {
                    working.aborted = true
                    finishEar()
                    return
                }
            } else {
                level = clampLevel(level + Self.stepDownDB)
            }

        case .descending:
            if heard {
                if level <= config.floorDBFS {
                    // Heard at the floor — can't measure lower. Record the
                    // floor as the (best-case) threshold.
                    finishFrequency(threshold: config.floorDBFS)
                    return
                }
                level = clampLevel(level - Self.stepDownDB)
            } else {
                mode = .ascending
                ascend()
            }

        case .ascending:
            // This presentation was an ascending arrival at `level`.
            if heard {
                let hits = (ascendingHits[level] ?? 0) + 1
                ascendingHits[level] = hits
                if hits >= Self.ascendingHitsRequired {
                    finishFrequency(threshold: level)
                    return
                }
                // Confirmed once — drop and come back up.
                mode = .descending
                level = clampLevel(level - Self.stepDownDB)
            } else {
                if level >= config.ceilingDBFS {
                    ceilingMisses += 1
                    if ceilingMisses >= Self.ceilingMissesForUnmeasurable {
                        finishFrequency(threshold: nil)
                        return
                    }
                }
                ascend()
            }
        }

        presentNext()
    }

    /// Advance past the between-ears interstitial.
    mutating func continueToNextEar() {
        guard case .earComplete = phase, completedEars.count == 1 else { return }
        startEar(earOrder[1])
    }

    // MARK: - Results

    /// Measurable thresholds as audiogram points (dB HL, rounded to the
    /// 5 dB grid, clamped to the chart's conventions). Unmeasurable
    /// frequencies are omitted — absent points derive no NAL-R band.
    func estimatedThresholds(for ear: TestEar) -> [AudiogramPoint] {
        guard let result = completedEars.first(where: { $0.ear == ear }) else { return [] }
        return result.frequencyResults.compactMap { fr in
            guard let dbfs = fr.thresholdDBFS else { return nil }
            let hl = (dbHL(fromDBFS: dbfs, at: fr.frequencyHz) / 5).rounded() * 5
            return AudiogramPoint(
                frequencyHz: Int(fr.frequencyHz),
                thresholddBHL: min(120, max(-10, hl))
            )
        }
        .sorted { $0.frequencyHz < $1.frequencyHz }
    }

    func earResult(_ ear: TestEar) -> EarResult? {
        completedEars.first { $0.ear == ear }
    }

    // MARK: - Internals

    /// One ascending step, clamped so the next presentation never exceeds
    /// the safety ceiling.
    private mutating func ascend() {
        level = clampLevel(level + Self.stepUpDB)
    }

    private mutating func startEar(_ ear: TestEar) {
        working = EarResult(ear: ear)
        freqIndex = 0
        startFrequency()
    }

    private mutating func startFrequency() {
        trialsThisFrequency = 0
        ascendingHits = [:]
        ceilingMisses = 0
        lastWasCatch = false

        let familiarizationLevel = clampLevel(
            dbFS(fromHL: Self.familiarizationStartHL, at: currentFrequency))

        if freqIndex == 0 {
            // Each ear familiarizes at its first frequency (1 kHz).
            mode = .familiarization
            level = familiarizationLevel
        } else {
            // Start above the most recent measurable threshold so the first
            // presentations are audible and the staircase descends into the
            // threshold from above.
            mode = .descending
            let reference = working.frequencyResults.last(where: { $0.thresholdDBFS != nil })?
                .thresholdDBFS ?? familiarizationLevel
            level = clampLevel(reference + Self.startAboveThresholdDB)
        }
        presentNext()
    }

    private mutating func presentNext() {
        // Runaway guard.
        if trialsThisFrequency >= Self.maxTrialsPerFrequency {
            working.hitTrialCap = true
            finishFrequency(threshold: level)
            return
        }

        let isFam = (mode == .familiarization)
        // Catch trials interleave with real staircase presentations —
        // never during familiarization, never two in a row.
        let isCatch = !isFam && !lastWasCatch && catchDecider()
        if !isCatch { trialsThisFrequency += 1 }

        phase = .presenting(Trial(
            ear: working.ear,
            frequencyHz: currentFrequency,
            levelDBFS: level,
            isCatch: isCatch,
            isFamiliarization: isFam
        ))
    }

    private mutating func finishFrequency(threshold: Double?) {
        working.frequencyResults.append(
            FrequencyResult(frequencyHz: currentFrequency, thresholdDBFS: threshold))

        if isRetest {
            // Reliability check: compare against the first 1 kHz run.
            let first = working.frequencyResults.first {
                $0.frequencyHz == Self.retestFrequency
            }?.thresholdDBFS
            if let first, let retest = threshold {
                working.retestDeltaDB = retest - first
            }
            // The retest is a validity probe, not a second data point —
            // drop it from the results (never silently average).
            working.frequencyResults.removeLast()
            finishEar()
            return
        }

        freqIndex += 1
        if freqIndex == Self.frequencySequence.count {
            // All eight measured — run the 1 kHz retest.
            startFrequency()
        } else {
            startFrequency()
        }
    }

    private mutating func finishEar() {
        completedEars.append(working)
        if completedEars.count == 1 {
            phase = .earComplete(working.ear)
        } else {
            phase = .finished
        }
    }
}
