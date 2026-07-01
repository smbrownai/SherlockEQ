import Foundation
import AVFoundation
import Accelerate
import Combine

/// vDSP-backed FFT spectrum analyzer that:
///   1. Installs a buffer tap on `AVAudioEngine.mainMixerNode` (post-EQ)
///   2. Accumulates mono samples into FFT-sized frames
///   3. Hann-windows, FFTs, magnitudes
///   4. Publishes a broadband RMS dBFS / dBA estimate and the raw bins
///
/// The FFT runs on a background queue; results are republished on the main
/// actor. Render-thread work is just memcpy into a small accumulator.
///
/// NOTE on "A-weighting": the dBA estimate published here is a broadband
/// RMS plus a fixed `calibrationOffsetDBA`. It is NOT a frequency-weighted
/// dBA per IEC 61672 — see the comment in `drainAndProcess` for the
/// rationale. The static `aWeightDB(frequencyHz:)` helper is exposed for
/// the canvas's per-bin safety threshold curve.
@MainActor
final class SpectrumAnalyzer: ObservableObject {

    static let fftSize: Int = 2048
    static let halfFFT: Int = fftSize / 2
    /// Output log-bucket count for the canvas. ~3 buckets per pixel at
    /// 800 pt wide → 256 is plenty and keeps each bucket cheap to draw.
    static let logBucketCount: Int = 256
    /// Lower frequency cutoff for the log-binned view.
    static let logMinHz: Double = 20
    /// Upper frequency cutoff (nyquist ceiling for the canvas).
    static let logMaxHz: Double = 20_000

    /// Per-bin dBFS magnitudes with attack/release smoothing applied — what
    /// the spectrum view should draw filled. Updated at FFT rate.
    @Published private(set) var spectrumBinsDB: [Float] = Array(repeating: -120, count: halfFFT)
    /// Per-bin peak-hold trace that climbs to recent maxima and then
    /// gradually decays. Drawn as a thin overlay line for that pro-tool feel.
    @Published private(set) var spectrumPeakHoldDB: [Float] = Array(repeating: -120, count: halfFFT)
    /// Same data as `spectrumBinsDB` but resampled onto log-spaced frequency
    /// buckets — what the parametric canvas should draw to avoid the
    /// cramped-bass / sparse-treble distribution of a linear FFT.
    @Published private(set) var logSpectrumDB: [Float] = Array(repeating: -120, count: logBucketCount)
    /// Log-binned peak hold mirroring `logSpectrumDB`.
    @Published private(set) var logSpectrumPeakHoldDB: [Float] = Array(repeating: -120, count: logBucketCount)
    /// Rolling history of recent `logSpectrumDB` frames — the spectrogram
    /// view consumes this as a time × frequency × dB heatmap. Oldest frame
    /// at index 0, newest at end. Capped at `spectrogramHistoryLength`.
    @Published private(set) var spectrogramHistory: [[Float]] = []
    static let spectrogramHistoryLength: Int = 180
    /// Broadband RMS over the most recent FFT frame, in dBFS. Name is
    /// historical — see the file header note; this is not frequency-
    /// weighted, but the dose tracker only needs a stable level estimate.
    @Published private(set) var aWeightedDBFS: Float = -120
    /// dBA estimate = dBFS + calibrationOffsetDBA.
    @Published private(set) var estimateDBA: Float = 0
    /// Whether the tap is currently installed.
    @Published private(set) var isAttached: Bool = false

    /// Smoothing weights — biased to fast attack, moderate release.
    /// Tuned so when audio stops the bars decay visibly within ~1 sec
    /// rather than lingering, which made transient silences look noisy.
    private var attackWeight: Float = 0.85
    private var releaseWeight: Float = 0.35
    /// Peak-hold drops by this much per FFT frame (≈23 fps).
    private var peakHoldDecayPerFrame: Float = 3.0

    /// Calibration: spec §5.4 acknowledges this is an estimate — full-scale
    /// digital ≠ a specific dB SPL without knowing the hardware. 100 dBA at
    /// 0 dBFS is a commonly used reasonable default for consumer playback.
    var calibrationOffsetDBA: Float = 100

    private let processingQueue = DispatchQueue(label: "com.shawnbrown.SherlockEQ.spectrum", qos: .userInitiated)

    // FFT state (created once, reused per frame).
    private let dftSetup: vDSP.DiscreteFourierTransform<Float>
    private var hannWindow: [Float]
    private var sampleRate: Double = 48000

    /// Render-thread-shared state, guarded by `accumulatorState`'s unfair
    /// lock rather than `NSLock` — matches `publishPending` below and every
    /// other cross-thread structure in the Audio module. `NSLock` is a
    /// pthread_mutex under the hood: it can put the calling thread to sleep
    /// and require a kernel round-trip under contention, unlike
    /// `os_unfair_lock`'s lightweight spin/wait tuned for realtime threads.
    /// Both audio-thread `ingest` overloads take this lock on every buffer.
    private struct AccumulatorState {
        // Sample accumulation across multiple tap callbacks.
        var accumulator: [Float] = []
        /// Number of attached observers. When zero, `ingest` returns
        /// immediately — no sample accumulation, no FFT, no publish, no
        /// allocation. The pre-EQ analyzer in particular sits dormant unless
        /// the Input layer is visible.
        var subscriberCount: Int = 0
        /// Wall-clock stamp of the last FFT dispatch.
        var lastDispatchTime: CFTimeInterval = 0
    }
    private let accumulatorState = OSAllocatedUnfairLock<AccumulatorState>(initialState: AccumulatorState())

    /// Hard cap on the accumulator so a slow main thread can't grow it
    /// unboundedly. ~150 ms of audio at 48 kHz. When we exceed this we
    /// drop oldest samples — we'd rather show a slightly truncated history
    /// than display data from a minute ago.
    private static let maxAccumulatorSamples = fftSize * 3

    /// Inflight-publish guard. Only one publish hops to the main actor at
    /// a time; further FFT results merge their smoothing in place and
    /// publish on the next available tick rather than queueing up.
    /// `OSAllocatedUnfairLock` is async-safe — NSLock would warn (then
    /// error in Swift 6) about its lock/unlock methods being called
    /// inside `Task { @MainActor in ... }` blocks.
    private let publishPending = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Minimum interval between FFT dispatches. The CATap callback at
    /// 48 kHz delivers fresh samples every ~5 ms, so without throttling
    /// we'd run an FFT every time the accumulator hit 2048 samples
    /// (~43 ms ≈ 23 Hz per analyzer). With two analyzers that compounds
    /// to ~46 Hz of FFT + main-actor publish work. 20 Hz is more than
    /// the eye can resolve on a spectrum display and matches what the
    /// dose tracker explicitly tolerates ("Call rate ~10 Hz is plenty").
    private static let minDispatchInterval: CFTimeInterval = 1.0 / 20.0

    /// Cheap level-emit cadence. The dose tracker needs roughly 20 Hz; this
    /// path fires `onLevelUpdate` directly from `ingest` so dose accounting
    /// keeps working even when nobody is observing the FFT pipeline.
    private static let levelEmitInterval: CFTimeInterval = 1.0 / 20.0
    /// Single-thread state: each analyzer's `ingest` is always called from
    /// one audio thread, so no lock is needed here.
    private var lastLevelEmitTime: CFTimeInterval = 0

    /// Fixed capacity for the mono mixdown scratch buffer below — 16x the
    /// requested tap buffer size (1024 frames; see
    /// `SherlockEQAudioEngine.installSpectrumTap`) and 4x the previous
    /// grow-on-demand ceiling. `AVAudioEngine` doesn't document a hard
    /// maximum for the size a tap callback can actually deliver, but no
    /// realistic buffer-size renegotiation should approach this — it's a
    /// safety margin, not a measured bound.
    private static let monoScratchCapacity = 16_384

    /// Pre-allocated mono mixdown buffer for the channel-mix ingest path.
    /// Fixed size, never reallocated — the render thread must never
    /// allocate, matching `BiquadCascade`'s delay buffer and
    /// `TapRingBuffer`'s storage. If a delivered buffer somehow exceeds
    /// `monoScratchCapacity` (violating the assumption above), `ingest`
    /// processes only the leading frames that fit rather than growing this
    /// array. Touched only from the single audio-thread caller (same
    /// invariant as `lastLevelEmitTime`), so it doesn't need synchronisation.
    private var monoScratch: [Float] = Array(repeating: 0, count: monoScratchCapacity)

    /// Callback for downstream consumers (SafeListeningTracker). Fires once
    /// per FFT frame with the most recent A-weighted level.
    var onLevelUpdate: ((_ dBA: Float) -> Void)?

    init() {
        // `vDSP.DiscreteFourierTransform` replaced the deprecated `vDSP.DFT`.
        // The new initializer throws (rather than failable) — fatalError on
        // the throw because we can't run without an FFT.
        do {
            self.dftSetup = try vDSP.DiscreteFourierTransform<Float>(
                previous: nil,
                count: Self.fftSize,
                direction: .forward,
                transformType: .complexComplex,
                ofType: Float.self
            )
        } catch {
            fatalError("Could not allocate vDSP DiscreteFourierTransform: \(error)")
        }
        var window = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        self.hannWindow = window
        // Reserve once so subsequent `append(contentsOf:)` calls on the
        // audio thread don't reallocate when the array grows.
        accumulatorState.withLock { $0.accumulator.reserveCapacity(Self.maxAccumulatorSamples) }
    }

    /// Feed a freshly-captured buffer. Realtime-safe — does no allocation
    /// beyond the accumulator append (which is bounded by FFT size).
    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let chCount = Int(buffer.format.channelCount)
        if frames == 0 || chCount == 0 { return }

        // === Cheap, always-on level pass ===
        // vDSP_measqv on channel 0 is microsecond work. Fires onLevelUpdate
        // at ~20 Hz so the dose tracker keeps integrating accurately even
        // when the expensive FFT pipeline is dormant (no canvas observer).
        var rawMS: Float = 0
        vDSP_measqv(channels[0], 1, &rawMS, vDSP_Length(frames))
        emitLevelIfDue(meanSquared: rawMS)

        // === Expensive path gate ===
        // FFT + smoothing + main-actor publish only run when someone is
        // looking at the spectrum. The accumulator stays empty while
        // dormant so a fresh subscribe doesn't FFT stale audio.
        guard accumulatorState.withLock({ $0.subscriberCount > 0 }) else { return }

        // Mix to mono — average of available channels. Write into the
        // pre-allocated scratch buffer rather than allocating fresh on
        // every ingest. vDSP_vsma does (src * w) + dst → dst per channel,
        // so we zero the scratch first and then accumulate. Clamp to the
        // scratch's fixed capacity rather than growing it — see
        // `monoScratchCapacity`'s doc comment.
        let mixFrames = min(frames, monoScratch.count)
        var weight: Float = 1.0 / Float(chCount)
        monoScratch.withUnsafeMutableBufferPointer { mPtr in
            guard let base = mPtr.baseAddress else { return }
            memset(base, 0, mixFrames * MemoryLayout<Float>.size)
            for ch in 0..<chCount {
                vDSP_vsma(channels[ch], 1, &weight, base, 1, base, 1, vDSP_Length(mixFrames))
            }
            appendToAccumulatorAndDispatch(
                source: UnsafeBufferPointer(start: base, count: mixFrames)
            )
        }
    }

    /// Raw-mono ingest path used by the pre-EQ side-channel from
    /// `CATapEngine` — the source-node render block delivers freshly-
    /// filled L samples here, bypassing the buffer-list mixing step.
    func ingest(monoSamples: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }

        // Cheap always-on level pass — same shape as the AVAudioPCMBuffer
        // ingest path. Already mono, so no channel selection needed.
        var rawMS: Float = 0
        vDSP_measqv(monoSamples, 1, &rawMS, vDSP_Length(frameCount))
        emitLevelIfDue(meanSquared: rawMS)

        guard accumulatorState.withLock({ $0.subscriberCount > 0 }) else { return }

        // Already mono — no scratch needed. Append straight from the
        // caller's pointer. The accumulator's reserved capacity (set at
        // init) keeps the append from reallocating in steady state.
        appendToAccumulatorAndDispatch(
            source: UnsafeBufferPointer(start: monoSamples, count: frameCount)
        )
    }

    /// Append a buffer of samples to the accumulator under the lock,
    /// trim to the high-water mark, and dispatch an FFT if due. Shared
    /// tail between the two ingest paths so the accumulator's hot path
    /// has one definition.
    private func appendToAccumulatorAndDispatch(source: UnsafeBufferPointer<Float>) {
        let shouldDispatch = accumulatorState.withLock { state -> Bool in
            state.accumulator.append(contentsOf: source)
            if state.accumulator.count > Self.maxAccumulatorSamples {
                state.accumulator.removeFirst(state.accumulator.count - Self.maxAccumulatorSamples)
            }
            return Self.shouldDispatch(&state)
        }

        if shouldDispatch {
            processingQueue.async { [weak self] in
                self?.drainAndProcess()
            }
        }
    }

    /// Combined gate: only dispatch a fresh FFT if we have enough samples
    /// AND we're outside the throttle window. Caller must already hold
    /// `accumulatorState`'s lock — both checks share it so no two callbacks
    /// race past the gate. Stamps `lastDispatchTime` on success.
    private nonisolated static func shouldDispatch(_ state: inout AccumulatorState) -> Bool {
        guard state.accumulator.count >= Self.fftSize else { return false }
        let now = CACurrentMediaTime()
        guard (now - state.lastDispatchTime) >= Self.minDispatchInterval else { return false }
        state.lastDispatchTime = now
        return true
    }

    /// Throttled emit of `onLevelUpdate` from the cheap level pass. Fires
    /// at ~20 Hz regardless of whether the FFT pipeline is running, so
    /// `SafeListeningTracker`'s NIOSH dose integration stays accurate when
    /// the canvas isn't visible and the analyzer is otherwise dormant.
    private func emitLevelIfDue(meanSquared: Float) {
        let now = CACurrentMediaTime()
        guard (now - lastLevelEmitTime) >= Self.levelEmitInterval else { return }
        lastLevelEmitTime = now
        let rms = sqrt(max(meanSquared, 1e-20))
        let dbfs = 20 * log10(rms)
        let dba = dbfs + calibrationOffsetDBA
        onLevelUpdate?(dba)
    }

    /// Add one observer. Pair with `unsubscribe()` on teardown. While the
    /// count is zero, `ingest` bails early and the analyzer does no work
    /// at all — no FFT, no main-actor publish, no allocations. Called from
    /// SwiftUI lifecycle (main thread); the lock keeps the audio-thread
    /// gate consistent.
    func subscribe() {
        accumulatorState.withLock { $0.subscriberCount += 1 }
    }

    /// Remove one observer. Idempotent at the floor (never goes negative).
    func unsubscribe() {
        accumulatorState.withLock { state in
            if state.subscriberCount > 0 { state.subscriberCount -= 1 }
            // Drop accumulated samples so a fresh subscribe doesn't
            // immediately FFT a frame of stale audio from before the
            // unsubscribe.
            if state.subscriberCount == 0 {
                state.accumulator.removeAll(keepingCapacity: true)
            }
        }
    }

    /// Configure tap-installation. The engine wrapper calls back with the
    /// buffer format so the log-bucket map can be rebuilt at the right SR.
    func configureForSampleRate(_ sr: Double) {
        sampleRate = sr
        rebuildLogBucketMap()
        accumulatorState.withLock { $0.accumulator.removeAll(keepingCapacity: true) }
        resetSmoothing()
        isAttached = true
    }

    func detached() {
        isAttached = false
        accumulatorState.withLock { $0.accumulator.removeAll(keepingCapacity: true) }
        resetSmoothing()
    }

    private func resetSmoothing() {
        spectrumBinsDB = Array(repeating: -120, count: Self.halfFFT)
        spectrumPeakHoldDB = Array(repeating: -120, count: Self.halfFFT)
        logSpectrumDB = Array(repeating: -120, count: Self.logBucketCount)
        logSpectrumPeakHoldDB = Array(repeating: -120, count: Self.logBucketCount)
        spectrogramHistory.removeAll(keepingCapacity: true)
        rebuildLogBucketMap()
    }

    /// For each FFT bin, the log bucket it falls into. Precomputed once per
    /// sample-rate change so the per-frame resampling is O(N).
    private var logBucketForBin: [Int] = []
    /// `logBucketIsReal[b]` is true iff at least one FFT bin maps to bucket
    /// `b`. Drives the per-frame gap-fill: empty buckets between two real
    /// anchors get linearly interpolated; outside the real range we hold
    /// the nearest anchor flat. Precomputed alongside `logBucketForBin`.
    private var logBucketIsReal: [Bool] = []

    private func rebuildLogBucketMap() {
        let n = Self.halfFFT
        let buckets = Self.logBucketCount
        let logMin = log10(Self.logMinHz)
        let logMax = log10(Self.logMaxHz)
        let logRange = logMax - logMin
        logBucketForBin = Array(repeating: -1, count: n)
        var real = [Bool](repeating: false, count: buckets)
        for k in 0..<n {
            let hz = Double(k) * sampleRate / Double(Self.fftSize)
            guard hz >= Self.logMinHz && hz <= Self.logMaxHz else { continue }
            let logHz = log10(hz)
            let bucket = Int(Double(buckets) * (logHz - logMin) / logRange)
            let clamped = max(0, min(buckets - 1, bucket))
            logBucketForBin[k] = clamped
            real[clamped] = true
        }
        logBucketIsReal = real
    }

    // MARK: - Background FFT

    private func drainAndProcess() {
        guard let frame = accumulatorState.withLock({ state -> [Float]? in
            guard state.accumulator.count >= Self.fftSize else { return nil }
            let frame = Array(state.accumulator.prefix(Self.fftSize))
            state.accumulator.removeFirst(Self.fftSize)
            return frame
        }) else { return }

        // === Level: time-domain RMS over the raw frame ===
        // Unambiguous and accurate regardless of FFT/window choices. NIOSH
        // dose math wants a level estimate; A-weighting would refine the dBA
        // estimate but is not required for the dose math to be roughly right.
        var meanSquared: Float = 0
        vDSP_measqv(frame, 1, &meanSquared, vDSP_Length(Self.fftSize))
        let rms = sqrt(max(meanSquared, 1e-20))
        let dbfs = 20 * log10(rms)
        let dba = dbfs + calibrationOffsetDBA

        // === Spectrum bins for visualisation (Session 13/14 will display) ===
        var windowed = [Float](repeating: 0, count: Self.fftSize)
        vDSP_vmul(frame, 1, hannWindow, 1, &windowed, 1, vDSP_Length(Self.fftSize))
        let imagInput = [Float](repeating: 0, count: Self.fftSize)
        var realOut = [Float](repeating: 0, count: Self.fftSize)
        var imagOut = [Float](repeating: 0, count: Self.fftSize)
        dftSetup.transform(
            inputReal: windowed, inputImaginary: imagInput,
            outputReal: &realOut, outputImaginary: &imagOut
        )
        // Squared magnitudes |X[k]|² in one vDSP call instead of a scalar
        // for-loop. `realOut`/`imagOut` are sized fftSize but vDSP_zvmags
        // only touches the first halfFFT entries (the positive-frequency
        // half — the negatives mirror).
        var magSquared = [Float](repeating: 0, count: Self.halfFFT)
        realOut.withUnsafeMutableBufferPointer { rPtr in
            imagOut.withUnsafeMutableBufferPointer { iPtr in
                var split = DSPSplitComplex(
                    realp: rPtr.baseAddress!,
                    imagp: iPtr.baseAddress!
                )
                vDSP_zvmags(&split, 1, &magSquared, 1, vDSP_Length(Self.halfFFT))
            }
        }
        // Normalise so bin values are dBFS-scaled. Without this, raw biquads
        // are in arbitrary 0…+60 dB range and the parametric canvas paints
        // a solid block instead of a varying spectrum.
        let invN2 = Float(1.0 / (Double(Self.fftSize) * Double(Self.fftSize)))
        // Floor on the un-scaled magSquared. Picking `1e-20 / invN2` here is
        // numerically equivalent to the previous `max(magSquared * invN2,
        // 1e-20)` clamp — both pin the eventual dB output at 10·log10(1e-20)
        // = -200 dB for any bin whose magnitude collapses to zero, so log10
        // never sees a literal zero.
        var rawFloor: Float = 1e-20 / invN2
        vDSP_vthr(magSquared, 1, &rawFloor, &magSquared, 1, vDSP_Length(Self.halfFFT))
        // dB = 10·log10(magSquared / N²). vDSP_vdbcon with flag=0 (power)
        // does exactly this with a single reference scalar — folding the
        // invN2 normalisation into the reference avoids a separate scaling
        // pass.
        var refSquared: Float = 1.0 / invN2  // = N²
        var dbBins = [Float](repeating: 0, count: Self.halfFFT)
        vDSP_vdbcon(
            magSquared, 1,
            &refSquared,
            &dbBins, 1,
            vDSP_Length(Self.halfFFT),
            0  // 0 = power (10·log10), 1 = amplitude (20·log10)
        )

        // Drop publishes if one is already on the main queue. The newer FFT
        // frame still gets folded in via smoothing as soon as the current
        // publish completes; we just don't pile up a backlog of stale ones.
        let shouldPublish = publishPending.withLock { pending -> Bool in
            guard !pending else { return false }
            pending = true
            return true
        }
        guard shouldPublish else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.publishSmoothed(rawDB: dbBins, dbfs: dbfs, dba: dba)
            self.publishPending.withLock { $0 = false }
        }
    }

    /// Run the FFT result through asymmetric exponential smoothing (fast
    /// attack, slow release) and a peak-hold trace, then publish.
    @MainActor
    private func publishSmoothed(rawDB: [Float], dbfs: Float, dba: Float) {
        guard rawDB.count == Self.halfFFT else { return }

        // Ensure prior arrays are sized; freshly attached or after reset they
        // may still hold the initial -120 floor.
        if spectrumBinsDB.count != Self.halfFFT {
            spectrumBinsDB = Array(repeating: -120, count: Self.halfFFT)
        }
        if spectrumPeakHoldDB.count != Self.halfFFT {
            spectrumPeakHoldDB = Array(repeating: -120, count: Self.halfFFT)
        }

        var smoothed = spectrumBinsDB
        var peaks = spectrumPeakHoldDB
        for k in 0..<Self.halfFFT {
            let new = rawDB[k]
            let prev = smoothed[k]
            // Asymmetric smoothing — rise quickly, fall gently.
            let weight: Float = new > prev ? attackWeight : releaseWeight
            smoothed[k] = prev * (1 - weight) + new * weight

            // Peak hold — climb to any new high; decay at a steady dB-per-frame.
            if new > peaks[k] {
                peaks[k] = new
            } else {
                peaks[k] = max(smoothed[k], peaks[k] - peakHoldDecayPerFrame)
            }
        }

        spectrumBinsDB = smoothed
        spectrumPeakHoldDB = peaks

        // Log-binned: each output bucket = max of the FFT bins mapped to it.
        // Max (not avg) preserves peaks across sparse-bin regions; otherwise
        // treble looks artificially flat.
        let buckets = Self.logBucketCount
        var logSmoothed = [Float](repeating: -120, count: buckets)
        var logPeaks = [Float](repeating: -120, count: buckets)
        for k in 0..<Self.halfFFT {
            let b = logBucketForBin[k]
            if b < 0 { continue }
            if smoothed[k] > logSmoothed[b] { logSmoothed[b] = smoothed[k] }
            if peaks[k] > logPeaks[b] { logPeaks[b] = peaks[k] }
        }
        // Fill empty buckets via LINEAR INTERPOLATION between the nearest
        // populated neighbours. Previously nearest-neighbour carry-forward
        // produced visible staircases at low frequencies where ~85 log
        // buckets per decade share only ~8 FFT bins (one bin every 23.4 Hz
        // at 2048-pt FFT @ 48 kHz). Interpolating in bucket-index space is
        // equivalent to interpolating in log-frequency space because the
        // bucket mapping is uniform in log-Hz.
        //
        // A bucket is "real" iff at least one FFT bin maps to it — recorded
        // once per sample-rate change in `logBucketIsReal`. We collect the
        // real indices, then for each gap between consecutive anchors ramp
        // linearly. Leading / trailing tails (before the first or after the
        // last anchor) are filled flat — extrapolating would invent data
        // outside what the FFT actually measured.
        var anchors: [Int] = []
        anchors.reserveCapacity(buckets)
        for b in 0..<buckets where logBucketIsReal[b] {
            anchors.append(b)
        }
        if let first = anchors.first, let last = anchors.last {
            for b in 0..<first {
                logSmoothed[b] = logSmoothed[first]
                logPeaks[b] = logPeaks[first]
            }
            for b in (last + 1)..<buckets {
                logSmoothed[b] = logSmoothed[last]
                logPeaks[b] = logPeaks[last]
            }
            for i in 0..<(anchors.count - 1) {
                let a = anchors[i]
                let z = anchors[i + 1]
                if z - a <= 1 { continue }
                let v0 = logSmoothed[a], v1 = logSmoothed[z]
                let p0 = logPeaks[a], p1 = logPeaks[z]
                let span = Float(z - a)
                for g in (a + 1)..<z {
                    let t = Float(g - a) / span
                    logSmoothed[g] = v0 + t * (v1 - v0)
                    logPeaks[g] = p0 + t * (p1 - p0)
                }
            }
        }
        logSpectrumDB = logSmoothed
        logSpectrumPeakHoldDB = logPeaks

        // Append to the spectrogram ring; trimming oldest frames when full.
        spectrogramHistory.append(logSmoothed)
        if spectrogramHistory.count > Self.spectrogramHistoryLength {
            spectrogramHistory.removeFirst(spectrogramHistory.count - Self.spectrogramHistoryLength)
        }

        aWeightedDBFS = dbfs
        estimateDBA = dba
        // NOTE: onLevelUpdate is NOT fired from here anymore. The cheap
        // `emitLevelIfDue` path in `ingest` owns it now, so dose tracking
        // keeps running at 20 Hz even when this FFT pipeline is dormant.
    }

    // MARK: - A-weighting

    /// A-weighting in DECIBELS at frequency `f`, per IEC 61672-1. Used by
    /// the canvas's per-bin safety threshold curve. At 1 kHz the result
    /// is 0 dB; below ~100 Hz and above ~12 kHz the values are strongly
    /// negative.
    static func aWeightDB(frequencyHz f: Double) -> Double {
        if f < 1 { return -200 }
        let f2 = f * f
        let num = pow(12_194.0, 2) * f2 * f2
        let den = (f2 + pow(20.6, 2))
            * sqrt((f2 + pow(107.7, 2)) * (f2 + pow(737.9, 2)))
            * (f2 + pow(12_194.0, 2))
        let R_A = num / den
        return 20 * log10(R_A) + 2.0
    }
}
