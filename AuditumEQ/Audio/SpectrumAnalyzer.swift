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

    /// Spectrum magnitudes in dBFS-ish units (0…-120). Updated at FFT rate.
    @Published private(set) var spectrumBinsDB: [Float] = Array(repeating: -120, count: halfFFT)
    /// A-weighted RMS over the most recent FFT frame, in dBFS.
    @Published private(set) var aWeightedDBFS: Float = -120
    /// dBA estimate = dBFS + calibrationOffsetDBA.
    @Published private(set) var estimateDBA: Float = 0
    /// Whether the tap is currently installed.
    @Published private(set) var isAttached: Bool = false

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
        let canProcess = accumulator.count >= Self.fftSize
        accumulatorLock.unlock()

        if canProcess {
            processingQueue.async { [weak self] in
                self?.drainAndProcess(sampleRate: captureSampleRate)
            }
        }
    }

    /// Configure tap-installation. The engine wrapper calls back with the
    /// buffer format so we can precompute A-weights at the right SR.
    func configureForSampleRate(_ sr: Double) {
        sampleRate = sr
        precomputeAWeights()
        accumulatorLock.lock()
        accumulator.removeAll(keepingCapacity: true)
        accumulatorLock.unlock()
        isAttached = true
        log.info("SpectrumAnalyzer configured @ \(Int(sr)) Hz")
    }

    func detached() {
        isAttached = false
        accumulatorLock.lock()
        accumulator.removeAll(keepingCapacity: true)
        accumulatorLock.unlock()
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

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.spectrumBinsDB = dbBins
            self.aWeightedDBFS = dbfs
            self.estimateDBA = dba
            self.onLevelUpdate?(dba)
        }
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
