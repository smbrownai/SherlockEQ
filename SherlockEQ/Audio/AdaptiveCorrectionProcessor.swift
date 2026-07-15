import Foundation
import os

/// Per-ear Adaptive Correction stage (phase4-adaptive-correction.md §3):
/// wraps one `AdaptiveFilterbank` with per-band level detectors and the
/// `AdaptiveCorrectionPrescription` gain rule, turning the audiogram's
/// static NAL-R correction into a level-following one. One instance per
/// ear, owned by `CATapEngine` (step 3), called from the source-node
/// render block between the AutoEQ stage and the dynamics processor.
///
/// Per render call:
///   1. snapshot config under the lock (once);
///   2. in `updateInterval`-sample chunks: compute each band's target gain
///      from its level envelope via the prescription, smooth it (~8 ms
///      one-pole in dB, 0.1 dB deadband), and hand the filterbank a
///      per-sample linear RAMP from the previous applied gain — zipper-free
///      by construction;
///   3. the filterbank measures each band's PRE-GAIN mean square
///      (feed-forward — the detector estimates the at-ear input level,
///      never chases its own gain), and the envelopes update with per-band
///      attack/release ballistics (slower on the two low bands: pumping on
///      bass transients is the classic WDRC artifact);
///   4. telemetry: applied gains land in `AudioCounter`s (milli-dB) for
///      the step-4 live overlay.
///
/// Realtime safety mirrors `DynamicBandProcessor`: config snapshots under
/// `OSAllocatedUnfairLock`; all runtime state pre-allocated; generation
/// bump → lazy audio-thread reset; the filterbank flushes denormals.
/// Disabled or bypassed, `process` returns without touching a sample —
/// bit-exact passthrough.
final class AdaptiveCorrectionProcessor {

    // MARK: - Tuning constants (spec §3 — one place)

    /// Samples between gain-computer updates (~1.3 ms at 48 kHz).
    static let updateInterval: Int = 64
    /// One-pole smoothing time constant on the prescribed gain.
    static let gainSmoothingSec: Double = 0.008
    /// Applied-gain movement below this (dB) is held — no micro-churn.
    static let gainDeadbandDB: Double = 0.1
    /// Detector ballistics: bands 0–1 (< 710 Hz) slower, 2–5 faster.
    static let attackSecLow: Double = 0.010
    static let releaseSecLow: Double = 0.150
    static let attackSecHigh: Double = 0.005
    static let releaseSecHigh: Double = 0.080
    /// Floor on band mean square before the dB conversion.
    static let meanSquareFloor: Float = 1e-12

    // MARK: - Config (main thread writes, audio thread snapshots)

    private struct ConfigState {
        var enabled = false
        var bypassed = false
        /// One entry per filterbank band; empty = not configured.
        var bands: [AdaptiveCorrectionPrescription.BandParameters] = []
        /// Phase-3 effective correction strength (target × ramp).
        var strength: Double = 1
        /// §7.3: false → the prescription's reduced-depth cap.
        var calibrated = true
        /// dBFS → dB SPL anchor (volume-anchored, Phase 1).
        var offsetDBA: Double = 100
        var sampleRate: Double = 48_000
        /// Bumped on any change that requires the audio thread to reset
        /// envelopes / gains / filter state before the next buffer.
        var generation = 0
    }

    private let stateLock = OSAllocatedUnfairLock<ConfigState>(initialState: ConfigState())

    // MARK: - Runtime state (audio thread only — no synchronisation)

    private let filterbank: AdaptiveFilterbank
    private var envelopeDB: [Double]
    private var smoothedGainDB: [Double]
    private var appliedGainDB: [Double]
    private var gainStart: [Float]
    private var gainEnd: [Float]
    private var bandMS: [Float]
    private var lastGeneration = -1

    /// Applied per-band gains in milli-dB — the telemetry the step-4 live
    /// overlay samples at display rate.
    private let counters: [AudioCounter]

    init(sampleRate: Double = 48_000) {
        filterbank = AdaptiveFilterbank(sampleRate: sampleRate)
        let n = AdaptiveFilterbank.bandCount
        envelopeDB = [Double](repeating: -120, count: n)
        smoothedGainDB = [Double](repeating: 0, count: n)
        appliedGainDB = [Double](repeating: 0, count: n)
        gainStart = [Float](repeating: 1, count: n)
        gainEnd = [Float](repeating: 1, count: n)
        bandMS = [Float](repeating: 0, count: n)
        counters = (0..<n).map { _ in AudioCounter() }
        stateLock.withLock { $0.sampleRate = sampleRate }
    }

    // MARK: - Main-thread API

    /// Push the per-band prescription + live scalars. Bands/enabled changes
    /// that (re)start processing bump the generation so the audio thread
    /// starts from clean state; scalar drift (strength ramping daily, the
    /// offset following the volume keys) deliberately does NOT reset —
    /// gains just glide to the new targets.
    func configure(
        bands: [AdaptiveCorrectionPrescription.BandParameters],
        strength: Double,
        calibrated: Bool,
        offsetDBA: Double,
        enabled: Bool
    ) {
        stateLock.withLock { state in
            let restarting = enabled && !state.enabled
            state.bands = bands
            state.strength = strength
            state.calibrated = calibrated
            state.offsetDBA = offsetDBA
            state.enabled = enabled && bands.count == AdaptiveFilterbank.bandCount
            // Only a disabled→enabled transition needs a cold start;
            // in-place band/scalar edits glide to their new targets.
            if restarting { state.generation &+= 1 }
        }
    }

    /// Live scalar updates between full configures (volume keys, daily
    /// ramp) — no reset, gains glide.
    func setStrength(_ strength: Double) {
        stateLock.withLock { $0.strength = strength }
    }

    func setOffsetDBA(_ offset: Double) {
        stateLock.withLock { $0.offsetDBA = offset }
    }

    func setCalibrated(_ calibrated: Bool) {
        stateLock.withLock { $0.calibrated = calibrated }
    }

    /// Reference-Mode bypass — mirrors `BiquadCascade.setBypassed`. Bumps
    /// the generation so un-bypassing resumes from clean state.
    func setBypassed(_ on: Bool) {
        stateLock.withLock { state in
            if state.bypassed != on {
                state.bypassed = on
                state.generation &+= 1
            }
        }
    }

    /// New delivered sample rate (engine rebuild — the render block is not
    /// running when this is called; the filterbank rewrites coefficient
    /// values in place, allocating nothing).
    func setSampleRate(_ sampleRate: Double) {
        filterbank.configure(sampleRate: sampleRate)
        stateLock.withLock { state in
            if state.sampleRate != sampleRate {
                state.sampleRate = sampleRate
                state.generation &+= 1
            }
        }
    }

    /// Clear to the inert state (profile without Adaptive mode, teardown).
    func clear() {
        stateLock.withLock { state in
            state.enabled = false
            state.bands = []
            state.generation &+= 1
        }
    }

    /// Telemetry read for the display-rate monitor (milli-dB).
    func currentGainMilliDB(band: Int) -> Int64 {
        guard counters.indices.contains(band) else { return 0 }
        return counters[band].read()
    }

    // MARK: - Audio thread

    /// Process one mono buffer in place. Realtime-safe; bit-exact
    /// passthrough when disabled or bypassed.
    func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        let cfg = stateLock.withLock { $0 }

        if cfg.generation != lastGeneration {
            lastGeneration = cfg.generation
            resetRuntime(cfg)
        }

        guard cfg.enabled, !cfg.bypassed,
              cfg.bands.count == AdaptiveFilterbank.bandCount,
              frameCount > 0
        else {
            if !cfg.enabled || cfg.bypassed {
                for c in counters { c.set(0) }
            }
            return
        }

        let n = AdaptiveFilterbank.bandCount
        var i = 0
        while i < frameCount {
            let chunk = min(Self.updateInterval, frameCount - i)
            let chunkSec = Double(chunk) / cfg.sampleRate

            // Gain computer: target from the CURRENT envelopes, smoothed,
            // deadbanded, handed to the filterbank as a per-sample ramp.
            let smoothAlpha = 1 - exp(-chunkSec / Self.gainSmoothingSec)
            for b in 0..<n {
                let inputSPL = envelopeDB[b] + cfg.offsetDBA
                let target = AdaptiveCorrectionPrescription.gainDB(
                    band: cfg.bands[b],
                    inputSPL: inputSPL,
                    strength: cfg.strength,
                    calibrated: cfg.calibrated
                )
                smoothedGainDB[b] += (target - smoothedGainDB[b]) * smoothAlpha
                let next = abs(smoothedGainDB[b] - appliedGainDB[b]) >= Self.gainDeadbandDB
                    ? smoothedGainDB[b]
                    : appliedGainDB[b]
                gainStart[b] = Float(pow(10.0, appliedGainDB[b] / 20.0))
                gainEnd[b] = Float(pow(10.0, next / 20.0))
                appliedGainDB[b] = next
            }

            bandMS.withUnsafeMutableBufferPointer { ms in
                filterbank.process(
                    samples + i, frameCount: chunk,
                    gainsStartLinear: gainStart, gainsEndLinear: gainEnd,
                    bandMeanSquares: ms.baseAddress
                )
            }

            // Detector: per-band attack/release envelope on the measured
            // pre-gain level (dBFS).
            for b in 0..<n {
                let levelDB = 10 * log10(Double(max(bandMS[b], Self.meanSquareFloor)))
                let rising = levelDB > envelopeDB[b]
                let tau: Double = b < 2
                    ? (rising ? Self.attackSecLow : Self.releaseSecLow)
                    : (rising ? Self.attackSecHigh : Self.releaseSecHigh)
                let alpha = 1 - exp(-chunkSec / tau)
                envelopeDB[b] += (levelDB - envelopeDB[b]) * alpha
            }

            i += chunk
        }

        for b in 0..<n {
            counters[b].set(Int64((appliedGainDB[b] * 1000).rounded()))
        }
    }

    /// Cold-start state: envelopes assume a moderate (reference-level)
    /// input so the first gains equal the NAL-R anchor and adapt from
    /// there — no full-quiet-gain onset pop when processing (re)starts.
    private func resetRuntime(_ cfg: ConfigState) {
        filterbank.reset()
        let n = AdaptiveFilterbank.bandCount
        let referenceDBFS = AdaptiveCorrectionPrescription.referenceSPL - cfg.offsetDBA
        for b in 0..<n {
            envelopeDB[b] = referenceDBFS
            let anchor = cfg.bands.count == n
                ? AdaptiveCorrectionPrescription.gainDB(
                    band: cfg.bands[b],
                    inputSPL: AdaptiveCorrectionPrescription.referenceSPL,
                    strength: cfg.strength,
                    calibrated: cfg.calibrated
                  )
                : 0
            smoothedGainDB[b] = anchor
            appliedGainDB[b] = anchor
        }
    }
}
