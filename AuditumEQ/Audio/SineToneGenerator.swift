import Foundation
import AVFoundation
import Combine
import OSLog

/// Continuously-phased sine generator for the Tone Finder (spec §5.10).
///
/// State (frequency, amplitude, playing) lives in a plain reference class so
/// the audio thread can read it without crossing an actor boundary — same
/// pattern as `CATapEngine.PreSpectrumIngestSlot`. The render block reads the
/// shared state every frame and smooths the frequency toward its target so
/// the user's sweep doesn't click or chirp.
@MainActor
final class SineToneGenerator: ObservableObject {

    /// Current target frequency (Hz). The render thread smooths the actual
    /// instantaneous freq toward this each sample.
    @Published var targetFrequencyHz: Double = 4000 {
        didSet { state.targetFrequency = targetFrequencyHz }
    }
    /// Output level — linear 0…1 scaling on the sine. 0.05 ≈ −26 dBFS RMS ≈
    /// ~75 dBA at typical calibration; safe for short pitch-matching use.
    @Published var amplitude: Float = 0.04 {
        didSet { state.amplitude = amplitude }
    }
    /// Master on/off — when false the render block emits silence.
    @Published private(set) var isPlaying: Bool = false {
        didSet { state.isPlaying = isPlaying }
    }

    private let log = Logger(subsystem: "com.shawnbrown.AuditumEQ", category: "ToneGen")
    private let state = ToneState()
    private(set) var sourceNode: AVAudioSourceNode?

    /// Plain reference class read by the audio thread, written from main.
    /// Property reads on the audio thread are racy with main-thread writes
    /// but for these small scalars that's acceptable — at worst we render
    /// one wrong sample before the new value is visible.
    private final class ToneState {
        var targetFrequency: Double = 4000
        var amplitude: Float = 0.04
        var isPlaying: Bool = false
        /// Smoothed instantaneous frequency the renderer updates each call.
        var smoothedFrequency: Double = 4000
        /// Continuous phase carried across render-block invocations.
        var phase: Double = 0
    }

    func makeSourceNode(sampleRate: Double, channels: AVAudioChannelCount = 2) -> AVAudioSourceNode? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
            return nil
        }
        state.smoothedFrequency = targetFrequencyHz
        state.targetFrequency = targetFrequencyHz
        state.amplitude = amplitude
        state.isPlaying = isPlaying
        state.phase = 0

        let toneState = state
        let twoPi = 2.0 * Double.pi
        let sr = sampleRate
        // Smoothing factor — per-sample exponential ramp toward the target
        // frequency. 0.0005 gives ~50 ms time constant at 48 kHz, fast
        // enough for live sweeping but slow enough to defeat clicks.
        let freqSmoothing = 0.0005

        let node = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let frames = Int(frameCount)
            let playing = toneState.isPlaying
            let amp = Double(toneState.amplitude)
            let target = toneState.targetFrequency
            var freq = toneState.smoothedFrequency
            var phase = toneState.phase

            for ch in 0..<buffers.count {
                guard let ptr = buffers[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                if !playing {
                    memset(ptr, 0, frames * MemoryLayout<Float>.size)
                }
            }
            if !playing {
                toneState.smoothedFrequency = target  // skip glide while silent
                return noErr
            }

            // Write into the first channel sample-by-sample, then copy to others.
            guard let firstPtr = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            for i in 0..<frames {
                freq += (target - freq) * freqSmoothing
                let sample = sin(phase) * amp
                firstPtr[i] = Float(sample)
                phase += twoPi * freq / sr
                if phase > twoPi { phase -= twoPi }
            }
            for ch in 1..<buffers.count {
                guard let ptr = buffers[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                memcpy(ptr, firstPtr, frames * MemoryLayout<Float>.size)
            }

            toneState.smoothedFrequency = freq
            toneState.phase = phase
            return noErr
        }

        self.sourceNode = node
        log.info("SineToneGenerator source node ready @ \(Int(sampleRate)) Hz")
        return node
    }

    func start() { isPlaying = true }
    func stop() { isPlaying = false }
    func toggle() { isPlaying.toggle() }
}
