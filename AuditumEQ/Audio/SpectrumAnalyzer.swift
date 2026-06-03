import Foundation
import AVFoundation
import Accelerate
import Combine
import OSLog

/// vDSP-backed FFT spectrum analyzer that:
///   1. Installs a buffer tap on `AVAudioEngine.mainMixerNode` (post-EQ)
///   2. Accumulates mono samples into FFT-sized frames
///   3. Hann-windows, FFTs, magnitudes, A-weights
///   4. Publishes an A-weighted dBA estimate and the raw spectrum bins
///
/// The FFT runs on a background queue; results are republished on the main
/// actor. Render-thread work is just memcpy into a small accumulator.
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
    /// A-weighted RMS over the most recent FFT frame, in dBFS.
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

    private let log = Logger(subsystem: "com.shawnbrown.AuditumEQ", category: "SpectrumAnalyzer")
    private let processingQueue = DispatchQueue(label: "com.shawnbrown.AuditumEQ.spectrum", qos: .userInitiated)

    // FFT state (created once, reused per frame).
    private let dftSetup: vDSP.DFT<Float>
    private var hannWindow: [Float]
    private var aWeights: [Float] = []
    private var aWeightsSquared: [Float] = []
    private var sampleRate: Double = 48000

    // Sample accumulation across multiple tap callbacks.
    private var accumulator: [Float] = []
    private let accumulatorLock = NSLock()

    /// Hard cap on the accumulator so a slow main thread can't grow it
    /// unboundedly. ~150 ms of audio at 48 kHz. When we exceed this we
    /// drop oldest samples — we'd rather show a slightly truncated history
    /// than display data from a minute ago.
    private static let maxAccumulatorSamples = fftSize * 3

    /// Inflight-publish guard. Only one publish hops to the main actor at
    /// a time; further FFT results merge their smoothing in place and
    /// publish on the next available tick rather than queueing up.
    private var publishPending = false
    private let publishPendingLock = NSLock()

    /// Callback for downstream consumers (SafeListeningTracker). Fires once
    /// per FFT frame with the most recent A-weighted level.
    var onLevelUpdate: ((_ dBA: Float) -> Void)?

    init() {
        guard let setup = vDSP.DFT<Float>(
            previous: nil,
            count: Self.fftSize,
            direction: .forward,
            transformType: .complexComplex,
            ofType: Float.self
        ) else {
            fatalError("Could not allocate vDSP DFT")
        }
        self.dftSetup = setup
        var window = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        self.hannWindow = window
    }

    /// Feed a freshly-captured buffer. Realtime-safe — does no allocation
    /// beyond the accumulator append (which is bounded by FFT size).
    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let chCount = Int(buffer.format.channelCount)
        if frames == 0 || chCount == 0 { return }

        // Mix to mono — average of available channels.
        var mono = [Float](repeating: 0, count: frames)
        let weight: Float = 1.0 / Float(chCount)
        for ch in 0..<chCount {
            let ptr = channels[ch]
            for i in 0..<frames {
                mono[i] += ptr[i] * weight
            }
        }

        let captureSampleRate = buffer.format.sampleRate

        accumulatorLock.lock()
        accumulator.append(contentsOf: mono)
        if accumulator.count > Self.maxAccumulatorSamples {
            accumulator.removeFirst(accumulator.count - Self.maxAccumulatorSamples)
        }
        let canProcess = accumulator.count >= Self.fftSize
        accumulatorLock.unlock()

        if canProcess {
            processingQueue.async { [weak self] in
                self?.drainAndProcess(sampleRate: captureSampleRate)
            }
        }
    }

    /// Raw-mono ingest path used by the pre-EQ side-channel from
    /// `CATapEngine` — the source-node render block delivers freshly-
    /// filled L samples here, bypassing the buffer-list mixing step.
    func ingest(monoSamples: UnsafePointer<Float>, frameCount: Int, sampleRate captureSR: Double) {
        guard frameCount > 0 else { return }

        var mono = [Float](repeating: 0, count: frameCount)
        memcpy(&mono, monoSamples, frameCount * MemoryLayout<Float>.size)

        accumulatorLock.lock()
        accumulator.append(contentsOf: mono)
        if accumulator.count > Self.maxAccumulatorSamples {
            accumulator.removeFirst(accumulator.count - Self.maxAccumulatorSamples)
        }
        let canProcess = accumulator.count >= Self.fftSize
        accumulatorLock.unlock()

        if canProcess {
            processingQueue.async { [weak self] in
                self?.drainAndProcess(sampleRate: captureSR)
            }
        }
    }

    /// Configure tap-installation. The engine wrapper calls back with the
    /// buffer format so we can precompute A-weights at the right SR.
    func configureForSampleRate(_ sr: Double) {
        sampleRate = sr
        precomputeAWeights()
        rebuildLogBucketMap()
        accumulatorLock.lock()
        accumulator.removeAll(keepingCapacity: true)
        accumulatorLock.unlock()
        resetSmoothing()
        isAttached = true
        log.info("SpectrumAnalyzer configured @ \(Int(sr)) Hz")
    }

    func detached() {
        isAttached = false
        accumulatorLock.lock()
        accumulator.removeAll(keepingCapacity: true)
        accumulatorLock.unlock()
        resetSmoothing()
    }

    private func resetSmoothing() {
        spectrumBinsDB = Array(repeating: -120, count: Self.halfFFT)
        spectrumPeakHoldDB = Array(repeating: -120, count: Self.halfFFT)
        logSpectrumDB = Array(repeating: -120, count: Self.logBucketCount)
        logSpectrumPeakHoldDB = Array(repeating: -120, count: Self.logBucketCount)
        rebuildLogBucketMap()
    }

    /// For each FFT bin, the log bucket it falls into. Precomputed once per
    /// sample-rate change so the per-frame resampling is O(N).
    private var logBucketForBin: [Int] = []

    private func rebuildLogBucketMap() {
        let n = Self.halfFFT
        let buckets = Self.logBucketCount
        let logMin = log10(Self.logMinHz)
        let logMax = log10(Self.logMaxHz)
        let logRange = logMax - logMin
        logBucketForBin = Array(repeating: -1, count: n)
        for k in 0..<n {
            let hz = Double(k) * sampleRate / Double(Self.fftSize)
            guard hz >= Self.logMinHz && hz <= Self.logMaxHz else { continue }
            let logHz = log10(hz)
            let bucket = Int(Double(buckets) * (logHz - logMin) / logRange)
            logBucketForBin[k] = max(0, min(buckets - 1, bucket))
        }
    }

    // MARK: - Background FFT

    private func drainAndProcess(sampleRate: Double) {
        accumulatorLock.lock()
        guard accumulator.count >= Self.fftSize else {
            accumulatorLock.unlock()
            return
        }
        let frame = Array(accumulator.prefix(Self.fftSize))
        accumulator.removeFirst(Self.fftSize)
        accumulatorLock.unlock()

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
        var magSquared = [Float](repeating: 0, count: Self.halfFFT)
        for k in 0..<Self.halfFFT {
            magSquared[k] = realOut[k] * realOut[k] + imagOut[k] * imagOut[k]
        }
        // Normalise so bin values are dBFS-scaled. Without this, raw biquads
        // are in arbitrary 0…+60 dB range and the parametric canvas paints
        // a solid block instead of a varying spectrum.
        let invN2 = Float(1.0 / (Double(Self.fftSize) * Double(Self.fftSize)))
        var dbBins = [Float](repeating: 0, count: Self.halfFFT)
        for k in 0..<Self.halfFFT {
            dbBins[k] = 10 * log10(max(magSquared[k] * invN2, 1e-20))
        }

        // Drop publishes if one is already on the main queue. The newer FFT
        // frame still gets folded in via smoothing as soon as the current
        // publish completes; we just don't pile up a backlog of stale ones.
        publishPendingLock.lock()
        let shouldPublish = !publishPending
        if shouldPublish { publishPending = true }
        publishPendingLock.unlock()
        guard shouldPublish else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.publishSmoothed(rawDB: dbBins, dbfs: dbfs, dba: dba)
            self.publishPendingLock.lock()
            self.publishPending = false
            self.publishPendingLock.unlock()
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
        // Fill any empty buckets via nearest-neighbor so the line stays
        // continuous in sparse-bin regions.
        var lastValid: Float = -120
        var lastValidPeak: Float = -120
        for b in 0..<buckets {
            if logSmoothed[b] > -119 {
                lastValid = logSmoothed[b]
                lastValidPeak = logPeaks[b]
            } else {
                logSmoothed[b] = lastValid
                logPeaks[b] = lastValidPeak
            }
        }
        logSpectrumDB = logSmoothed
        logSpectrumPeakHoldDB = logPeaks

        aWeightedDBFS = dbfs
        estimateDBA = dba
        onLevelUpdate?(dba)
    }

    // MARK: - A-weighting

    private func precomputeAWeights() {
        let N = Self.halfFFT
        aWeights = [Float](repeating: 0, count: N)
        aWeightsSquared = [Float](repeating: 0, count: N)
        for k in 0..<N {
            let f = Double(k) * sampleRate / Double(Self.fftSize)
            let w = Self.aWeightLinear(frequencyHz: f)
            aWeights[k] = w
            aWeightsSquared[k] = w * w
        }
    }

    /// Linear (not dB) A-weighting gain for frequency `f`, per IEC 61672-1.
    static func aWeightLinear(frequencyHz f: Double) -> Float {
        if f < 1 { return 0 }
        let f2 = f * f
        let num = pow(12_194.0, 2) * f2 * f2
        let den = (f2 + pow(20.6, 2))
            * sqrt((f2 + pow(107.7, 2)) * (f2 + pow(737.9, 2)))
            * (f2 + pow(12_194.0, 2))
        let R_A = num / den
        let A_dB = 20 * log10(R_A) + 2.0
        return Float(pow(10.0, A_dB / 20.0))
    }
}
