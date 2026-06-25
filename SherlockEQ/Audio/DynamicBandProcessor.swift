import Foundation
import os

/// Per-ear, level-dependent ("dynamic") EQ stage. Sits in the source-node
/// render block immediately after the static `BiquadCascade`, before the
/// peak counters and pre-spectrum side-channel, so every observer sees the
/// post-dynamics signal the user hears. One instance per ear, owned by
/// `CATapEngine` (captured strongly into the render block, like the
/// cascades).
///
/// It hosts up to three feature slots (`DynamicFeatureKind`). Each slot,
/// per render call:
///   1. runs a sidechain band-pass detector over the (post-static-EQ) input;
///   2. tracks a slow (~3 s) rolling average of the detector level and sets
///      an adaptive threshold = average + the user's sensitivity offset;
///   3. runs an attack/release envelope on the soft-kneed overshoot;
///   4. maps the envelope through the feature's ratio to a target gain
///      delta, clamped to the strength-scaled max (cut features negative,
///      Speech Presence positive);
///   5. smooths the target delta (~5 ms) to kill zipper noise;
///   6. every `updateInterval` samples, if the smoothed delta moved past a
///      deadband, recomputes the main bell's cookbook coefficients at the
///      current delta and swaps them in;
///   7. runs the modulated bell over the buffer in place. A slot whose
///      smoothed delta sits below `restThresholdDB` skips the bell entirely
///      — at rest the stage is sidechain-only.
///
/// Realtime safety mirrors `BiquadCascade`: the audio thread snapshots the
/// config under an `OSAllocatedUnfairLock` once per buffer; all detector /
/// envelope / filter state is pre-allocated at init; coefficient recompute
/// is pure libm math (`BiquadCoefficients.cookbook`) with no heap activity;
/// denormals flush once per buffer.
final class DynamicBandProcessor {

    // MARK: - Tuning constants (engineering, not user-facing)

    /// Samples between main-bell coefficient recomputes. Halve this first
    /// if listening tests ever surface zipper artifacts (spec §3.4).
    static let updateInterval: Int = 64
    /// Smoothed-delta movement (dB) required before a coefficient recompute.
    static let coeffDeadbandDB: Float = 0.1
    /// |smoothed delta| below this (dB) → the bell is bypassed for the buffer.
    static let restThresholdDB: Float = 0.1
    /// Gain-smoothing time constant (ms) on the target delta — kills zipper.
    static let gainSmoothingMs: Double = 5
    /// Rolling-average time constant (s) for the adaptive threshold.
    static let thresholdTauSec: Double = 3
    /// RMS detector window (ms) for the `.rms` feature detectors.
    static let detectorRmsMs: Double = 10
    /// Floor on the rolling average (dBFS) so silence can't drag the
    /// threshold into the noise floor and false-trigger on resume.
    static let averageFloorDB: Float = -70
    /// Lower bound on detector magnitude before the dB conversion.
    static let magnitudeFloor: Float = 1e-9
    /// Denormal flush threshold — matches `BiquadCascade`.
    static let denormalThreshold: Float = 1e-25

    // MARK: - Config (main thread writes, audio thread snapshots)

    /// One configured slot. POD — folded from `profile.dynamics` at
    /// `applyProfile` time. The strength/sensitivity sliders are already
    /// mapped to `maxDeltaDB` / `thresholdOffsetDB` by the caller so the
    /// audio thread does no slider arithmetic.
    struct SlotConfig {
        var kind: DynamicFeatureKind
        var enabled: Bool
        /// Sign-carrying, strength-scaled max gain delta (dB).
        var maxDeltaDB: Double
        /// Threshold offset above the rolling average (dB).
        var thresholdOffsetDB: Double
    }

    private struct ConfigState {
        var slots: [SlotConfig] = []
        var bypassed: Bool = false
        var sampleRate: Double = 48_000
        /// Bumped on any change that requires the audio thread to reset
        /// its detector / envelope / filter state.
        var generation: Int = 0
    }

    private let stateLock = OSAllocatedUnfairLock<ConfigState>(
        initialState: ConfigState()
    )

    // MARK: - Runtime state (audio thread only — no synchronisation)

    /// Normalised biquad (a0 factored out), Direct Form II transposed. The
    /// per-block modulated bell recomputes coefficients every buffer, so this
    /// stays a hand-rolled single-section recurrence rather than a
    /// `vDSP_biquad` setup (which would reallocate on each coefficient change);
    /// the static `BiquadCascade` uses vDSP because its coefficients are stable
    /// between profile edits.
    private struct Biquad {
        var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    }

    /// Per-slot audio-thread state. Fixed array of `slotCount`, pre-allocated
    /// at init — a config change never allocates here.
    private struct SlotRuntime {
        // Sidechain detector band-pass (fixed per kind + SR).
        var detector = Biquad()
        var dz1: Float = 0, dz2: Float = 0
        // RMS detector mean-square accumulator.
        var meanSquare: Float = 0
        // Adaptive threshold rolling average (dB).
        var averageDB: Float = DynamicBandProcessor.averageFloorDB
        // Attack/release envelope on the kneed overshoot (dB, ≥ 0).
        var envelopeDB: Float = 0
        // Smoothed target gain delta (dB, sign-carrying).
        var smoothedDeltaDB: Float = 0
        // Main modulated bell.
        var bell = Biquad()
        var bz1: Float = 0, bz2: Float = 0
        // Coefficient-update bookkeeping.
        var sampleCounter: Int = 0
        var lastAppliedDeltaDB: Float = .infinity   // forces a first recompute
    }

    private static let slotCount = 3
    private var runtime: [SlotRuntime] = Array(repeating: SlotRuntime(), count: DynamicBandProcessor.slotCount)
    private var lastGeneration: Int = -1
    private var configuredSR: Double = 48_000

    /// Signed milli-dB telemetry per slot, sampled by the UI at ~10–20 Hz.
    /// One counter per `DynamicFeatureKind`; this processor owns three (its
    /// ear's half of the six total).
    private let counters: [AudioCounter] = [AudioCounter(), AudioCounter(), AudioCounter()]

    init() {}

    /// Stable 0-based slot index for a kind — switch, not `allCases`
    /// (`allCases` allocates an array, forbidden on the audio thread).
    private static func slotIndex(_ kind: DynamicFeatureKind) -> Int {
        switch kind {
        case .speechPresence:   return 0
        case .harshnessControl: return 1
        case .sibilanceTamer:   return 2
        }
    }

    // MARK: - Configuration (main thread)

    /// Replace the active slot set. Bumps the generation — forcing the
    /// audio thread to reset state and recompute detector coefficients —
    /// only when the set of *running* slots changes (a feature enabled or
    /// disabled, or a kind/SR change). Strength/sensitivity-only edits
    /// take effect on the next buffer without an envelope reset, because
    /// `maxDeltaDB` / `thresholdOffsetDB` are read fresh from the snapshot
    /// each call — so dragging an unrelated EQ band (which re-runs
    /// `applyProfile`) doesn't glitch an engaged dynamic feature.
    func configure(slots: [SlotConfig]) {
        let capped = slots.count > Self.slotCount ? Array(slots.prefix(Self.slotCount)) : slots
        stateLock.withLock { state in
            let runningSetChanged = state.slots.count != capped.count
                || zip(state.slots, capped).contains { $0.kind != $1.kind || $0.enabled != $1.enabled }
            state.slots = capped
            if runningSetChanged { state.generation &+= 1 }
        }
    }

    /// Set the delivered sample rate (call alongside the cascades' rate
    /// context in `applyTapPrep`). Recomputes detector + bell coefficients
    /// against the correct Nyquist via a generation bump.
    func setSampleRate(_ sampleRate: Double) {
        stateLock.withLock { state in
            if state.sampleRate != sampleRate {
                state.sampleRate = sampleRate
                state.generation &+= 1
            }
        }
    }

    /// Reference-Mode bypass — mirrors `BiquadCascade.setBypassed`. Bumps
    /// the generation so re-enabling resumes from clean state.
    func setBypassed(_ on: Bool) {
        stateLock.withLock { state in
            if state.bypassed != on {
                state.bypassed = on
                state.generation &+= 1
            }
        }
    }

    /// Current smoothed gain delta for a slot, signed milli-dB. UI-thread
    /// read of the established `AudioCounter` atomics pattern.
    func currentDeltaMilliDB(_ kind: DynamicFeatureKind) -> Int64 {
        counters[Self.slotIndex(kind)].read()
    }

    // MARK: - Processing (audio thread)

    /// Filter `count` samples in place. Single channel per instance,
    /// matching the cascade — the host wires one processor to each ear's
    /// source-node render block.
    func process(samples: UnsafeMutablePointer<Float>, count: Int) {
        let snapshot = stateLock.withLock { $0 }
        if snapshot.bypassed { return }

        let sr = snapshot.sampleRate

        // Generation change → reset state + recompute detector coefficients.
        if snapshot.generation != lastGeneration {
            resetRuntime(for: snapshot, sampleRate: sr)
            lastGeneration = snapshot.generation
            configuredSR = sr
        }

        if snapshot.slots.isEmpty || count <= 0 { return }

        // Per-buffer smoothing coefficients (SR-dependent, constant across
        // the buffer). Cheap to recompute each call; no per-sample exp().
        let avgCoef = onePoleCoef(tauSeconds: Self.thresholdTauSec, sampleRate: sr)
        let rmsCoef = onePoleCoef(tauMs: Self.detectorRmsMs, sampleRate: sr)
        let gainCoef = onePoleCoef(tauMs: Self.gainSmoothingMs, sampleRate: sr)

        for slot in snapshot.slots where slot.enabled {
            let kind = slot.kind
            let idx = Self.slotIndex(kind)
            let attackCoef = onePoleCoef(tauMs: kind.attackMs, sampleRate: sr)
            let releaseCoef = onePoleCoef(tauMs: kind.releaseMs, sampleRate: sr)
            let offset = Float(slot.thresholdOffsetDB)
            let maxDelta = Float(slot.maxDeltaDB)
            let oneOverRatio = Float(1.0 / max(1.0, kind.ratio))
            let slope = 1 - oneOverRatio                  // gain change per dB of overshoot
            let halfKnee = Float(kind.kneeDB) * 0.5
            let twoKnee = Float(kind.kneeDB) * 2.0
            let isPeak = kind.detectorType == .peak
            let boosting = maxDelta >= 0
            // Overshoot past this point can't move the (clamped) gain any
            // further, so the envelope is capped here. Without the cap the
            // envelope accumulates the full raw overshoot (tens of dB on a
            // loud trigger) and the release time-to-rest would scale with
            // how loud the trigger was — the gain would stay pegged long
            // after the feature's release constant. Capping makes release
            // depend only on the ballistics, as intended.
            let overshootCeil: Float = slope > 0 ? abs(maxDelta) / slope + halfKnee : 0

            runtime.withUnsafeMutableBufferPointer { rt in
                var st = rt[idx]

                for i in 0..<count {
                    let x = samples[i]

                    // 1. Sidechain detect (feed-forward: reads input before
                    //    this slot's gain is applied).
                    let d = biquadSample(x, st.detector, &st.dz1, &st.dz2)
                    let magnitude: Float
                    if isPeak {
                        magnitude = abs(d)
                    } else {
                        st.meanSquare += (d * d - st.meanSquare) * rmsCoef
                        magnitude = st.meanSquare.squareRoot()
                    }
                    let levelDB = 20 * log10(max(magnitude, Self.magnitudeFloor))

                    // 2. Adaptive threshold.
                    st.averageDB += (levelDB - st.averageDB) * avgCoef
                    if st.averageDB < Self.averageFloorDB { st.averageDB = Self.averageFloorDB }
                    let threshold = st.averageDB + offset
                    let over = levelDB - threshold

                    // Soft-knee overshoot (≥ 0): smooth corner at the knee,
                    // capped at the point past which the clamped gain stops
                    // responding.
                    var kneed: Float
                    if over <= -halfKnee {
                        kneed = 0
                    } else if over >= halfKnee {
                        kneed = over
                    } else {
                        let t = over + halfKnee
                        kneed = (t * t) / twoKnee
                    }
                    if kneed > overshootCeil { kneed = overshootCeil }

                    // 3. Attack/release envelope on the kneed overshoot.
                    let coef = kneed > st.envelopeDB ? attackCoef : releaseCoef
                    st.envelopeDB += (kneed - st.envelopeDB) * coef

                    // 4. Gain computer: envelope → target delta via ratio,
                    //    clamped to the strength-scaled max.
                    let magnitudeDelta = st.envelopeDB * (1 - oneOverRatio)
                    var target = boosting ? magnitudeDelta : -magnitudeDelta
                    if boosting {
                        if target > maxDelta { target = maxDelta }
                        if target < 0 { target = 0 }
                    } else {
                        if target < maxDelta { target = maxDelta }
                        if target > 0 { target = 0 }
                    }

                    // 5. Gain smoothing.
                    st.smoothedDeltaDB += (target - st.smoothedDeltaDB) * gainCoef

                    // 6. Coefficient update at block rate, past the deadband.
                    st.sampleCounter += 1
                    if st.sampleCounter >= Self.updateInterval {
                        st.sampleCounter = 0
                        if abs(st.smoothedDeltaDB - st.lastAppliedDeltaDB) >= Self.coeffDeadbandDB {
                            st.bell = Self.makeBell(kind: kind, gainDB: st.smoothedDeltaDB, sampleRate: sr)
                            st.lastAppliedDeltaDB = st.smoothedDeltaDB
                        }
                    }

                    // 7. Process — bypass the bell entirely at rest.
                    if abs(st.smoothedDeltaDB) < Self.restThresholdDB {
                        // At rest the bell would be ~identity anyway; skip
                        // it and keep its state clean so re-engage is glitchless.
                        st.bz1 = 0
                        st.bz2 = 0
                        st.lastAppliedDeltaDB = .infinity  // force recompute on re-engage
                    } else {
                        samples[i] = biquadSample(x, st.bell, &st.bz1, &st.bz2)
                    }
                }

                // Denormal flush, once per buffer (O(1) per slot).
                if abs(st.dz1) < Self.denormalThreshold { st.dz1 = 0 }
                if abs(st.dz2) < Self.denormalThreshold { st.dz2 = 0 }
                if abs(st.bz1) < Self.denormalThreshold { st.bz1 = 0 }
                if abs(st.bz2) < Self.denormalThreshold { st.bz2 = 0 }
                if abs(st.meanSquare) < Self.denormalThreshold { st.meanSquare = 0 }

                rt[idx] = st
            }

            // Telemetry: signed milli-dB of the current smoothed delta.
            counters[idx].set(Int64(runtime[idx].smoothedDeltaDB * 1000))
        }
    }

    // MARK: - State reset & coefficient math

    /// Zero all envelopes/averages/filter state and recompute the per-slot
    /// detector band-pass coefficients for the current sample rate. Runs on
    /// the audio thread when the generation changes (config / SR / bypass) —
    /// pure libm math, no allocation, same shape as the cascade's
    /// section-count memset.
    private func resetRuntime(for snapshot: ConfigState, sampleRate sr: Double) {
        for idx in 0..<Self.slotCount {
            runtime[idx] = SlotRuntime()
        }
        for slot in snapshot.slots {
            let idx = Self.slotIndex(slot.kind)
            runtime[idx].detector = Self.makeDetector(kind: slot.kind, sampleRate: sr)
        }
    }

    /// Constant-skirt band-pass for a kind's detector band, as a normalised
    /// biquad. Converts the (low, high) corners to centre + Q.
    private static func makeDetector(kind: DynamicFeatureKind, sampleRate: Double) -> Biquad {
        let (low, high) = kind.detectorBand
        let center = (low * high).squareRoot()
        let q = center / max(1.0, high - low)
        let c = BiquadCoefficients.cookbook(
            filterType: .bandPass, freqHz: center, q: q, gainDB: 0, sampleRate: sampleRate
        )
        return normalized(c)
    }

    /// The modulated main bell at the current gain delta, normalised.
    private static func makeBell(kind: DynamicFeatureKind, gainDB: Float, sampleRate: Double) -> Biquad {
        let c = BiquadCoefficients.cookbook(
            filterType: .parametric,
            freqHz: kind.filterCenterHz,
            q: kind.filterQ,
            gainDB: Double(gainDB),
            sampleRate: sampleRate
        )
        return normalized(c)
    }

    private static func normalized(_ c: BiquadCoefficients) -> Biquad {
        guard c.a0 != 0 else { return Biquad() }
        return Biquad(
            b0: Float(c.b0 / c.a0),
            b1: Float(c.b1 / c.a0),
            b2: Float(c.b2 / c.a0),
            a1: Float(c.a1 / c.a0),
            a2: Float(c.a2 / c.a0)
        )
    }

    /// One DF2T biquad sample.
    @inline(__always)
    private func biquadSample(_ x: Float, _ s: Biquad, _ z1: inout Float, _ z2: inout Float) -> Float {
        let y = s.b0 * x + z1
        z1 = s.b1 * x - s.a1 * y + z2
        z2 = s.b2 * x - s.a2 * y
        return y
    }

    /// One-pole smoothing coefficient for a time constant. `coef = 1 −
    /// e^(−1/(τ·SR))`; applied as `state += (target − state) · coef`.
    @inline(__always)
    private func onePoleCoef(tauSeconds tau: Double, sampleRate sr: Double) -> Float {
        guard tau > 0, sr > 0 else { return 1 }
        return Float(1 - exp(-1.0 / (tau * sr)))
    }

    @inline(__always)
    private func onePoleCoef(tauMs: Double, sampleRate sr: Double) -> Float {
        onePoleCoef(tauSeconds: tauMs / 1000.0, sampleRate: sr)
    }
}
