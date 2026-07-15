import Foundation
import AVFoundation
import Combine
import os

/// Continuously-phased sine generator for the Tone Finder (spec §5.10).
///
/// State (frequency, amplitude, playing, plus the smoothing accumulator
/// and the running phase) lives in a `nonisolated` reference class so the
/// audio render block can touch it without crossing an actor boundary —
/// same pattern as `CATapEngine.PreSpectrumIngestSlot`. All fields are
/// behind an `OSAllocatedUnfairLock`, so a `Double` write from main can't
/// tear under an audio-thread read. The render block snapshots once per
/// call, runs the sample loop on locals, and writes the per-buffer state
/// back at the end — two lock acquires per render block, no contention
/// inside the inner loop.
@MainActor
final class SineToneGenerator: ObservableObject {

    /// Current target frequency (Hz). The render thread smooths the actual
    /// instantaneous freq toward this each sample.
    @Published var targetFrequencyHz: Double = 4000 {
        didSet { state.setTargetFrequency(targetFrequencyHz) }
    }
    /// Output level — linear 0…1 scaling on the sine. 0.05 ≈ −26 dBFS RMS ≈
    /// ~75 dBA at typical calibration; safe for short pitch-matching use.
    @Published var amplitude: Float = 0.04 {
        didSet { state.setAmplitude(amplitude) }
    }
    /// Master on/off — when false the render block emits silence.
    @Published private(set) var isPlaying: Bool = false {
        didSet { state.setIsPlaying(isPlaying) }
    }
    /// Pulsed presentation for the Listening Check (spec §4.2): 200 ms on /
    /// 200 ms off with 5 ms raised-cosine ramps on every edge — a hard-keyed
    /// sine clicks, and clicks are audible below the tone's own threshold.
    /// False (default) = continuous tone (Tone Finder unchanged).
    var pulsed: Bool = false {
        didSet { state.setPulsing(pulsed) }
    }
    /// Which output channels carry the tone — per-ear presentation for the
    /// Listening Check. Both true by default (Tone Finder unchanged).
    func setChannels(left: Bool, right: Bool) {
        channelLeft = left
        channelRight = right
        state.setChannelMask(left: left, right: right)
    }
    private var channelLeft = true
    private var channelRight = true

    private let state = ToneState()
    private(set) var sourceNode: AVAudioSourceNode?

    /// Cross-thread tone state — written from main, read+written from the
    /// audio render block. `nonisolated` so the render block can call its
    /// methods; all fields are wrapped in `OSAllocatedUnfairLock` so the
    /// reads and writes are atomic across threads.
    nonisolated final class ToneState: @unchecked Sendable {
        struct Fields {
            var targetFrequency: Double = 4000
            var amplitude: Float = 0.04
            var isPlaying: Bool = false
            var pulsing: Bool = false
            var leftEnabled: Bool = true
            var rightEnabled: Bool = true
            /// Smoothed instantaneous frequency the renderer updates each call.
            var smoothedFrequency: Double = 4000
            /// Continuous phase carried across render-block invocations.
            var phase: Double = 0
            /// Sample position inside the 400 ms pulse cycle, carried across
            /// render blocks like `phase`. Reset when playback (re)starts so
            /// every trial begins at a pulse onset.
            var pulsePosition: Int = 0
        }

        private let lock = OSAllocatedUnfairLock<Fields>(initialState: Fields())

        // Main-thread writers.
        func setTargetFrequency(_ v: Double) { lock.withLock { $0.targetFrequency = v } }
        func setAmplitude(_ v: Float) { lock.withLock { $0.amplitude = v } }
        func setIsPlaying(_ v: Bool) {
            lock.withLock {
                $0.isPlaying = v
                // Every (re)start begins at a pulse onset so the trial's
                // response window aligns with what the ear receives.
                if v { $0.pulsePosition = 0 }
            }
        }
        func setPulsing(_ v: Bool) { lock.withLock { $0.pulsing = v } }
        func setChannelMask(left: Bool, right: Bool) {
            lock.withLock {
                $0.leftEnabled = left
                $0.rightEnabled = right
            }
        }

        /// Reset the per-buffer accumulator state (smoothedFrequency, phase)
        /// alongside seeding the cross-thread fields — used by node creation.
        func seed(
            targetFrequency: Double, amplitude: Float, isPlaying: Bool,
            pulsing: Bool, leftEnabled: Bool, rightEnabled: Bool
        ) {
            lock.withLock {
                $0.targetFrequency = targetFrequency
                $0.amplitude = amplitude
                $0.isPlaying = isPlaying
                $0.pulsing = pulsing
                $0.leftEnabled = leftEnabled
                $0.rightEnabled = rightEnabled
                $0.smoothedFrequency = targetFrequency
                $0.phase = 0
                $0.pulsePosition = 0
            }
        }

        /// Atomic snapshot for the audio render block. Returns a copy of all
        /// fields so the inner sample loop can run on locals.
        func snapshot() -> Fields { lock.withLock { $0 } }

        /// Write back the per-buffer accumulator state at the end of a
        /// render block. Doesn't touch target/amplitude/isPlaying — main
        /// is the writer for those.
        func writeBack(smoothedFrequency: Double, phase: Double, pulsePosition: Int) {
            lock.withLock {
                $0.smoothedFrequency = smoothedFrequency
                $0.phase = phase
                $0.pulsePosition = pulsePosition
            }
        }
    }

    func makeSourceNode(sampleRate: Double, channels: AVAudioChannelCount = 2) -> AVAudioSourceNode? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
            return nil
        }
        state.seed(
            targetFrequency: targetFrequencyHz,
            amplitude: amplitude,
            isPlaying: isPlaying,
            pulsing: pulsed,
            leftEnabled: channelLeft,
            rightEnabled: channelRight
        )

        let toneState = state
        let twoPi = 2.0 * Double.pi
        let sr = sampleRate
        // Smoothing factor — per-sample exponential ramp toward the target
        // frequency. 0.0005 gives ~50 ms time constant at 48 kHz, fast
        // enough for live sweeping but slow enough to defeat clicks.
        let freqSmoothing = 0.0005
        // Pulse-train geometry (Listening Check): 200 ms on / 200 ms off,
        // 5 ms raised-cosine ramps inside the on-portion's edges.
        let pulseOnSamples = Int(0.2 * sampleRate)
        let pulseCycleSamples = Int(0.4 * sampleRate)
        let pulseRampSamples = max(1, Int(0.005 * sampleRate))

        let node = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            // Never trust frameCount alone — clamp to the smallest byte-size-
            // derived capacity among the delivered buffers, matching the same
            // guard CATapEngine's render blocks use, so a mismatched/stale
            // AudioBufferList can't drive an overrun in the loop/memcpy below.
            var frames = Int(frameCount)
            for buf in buffers {
                frames = min(frames, Int(buf.mDataByteSize) / MemoryLayout<Float>.size)
            }

            // Single atomic snapshot of all cross-thread fields. The
            // sample loop below runs purely on the locals.
            let s = toneState.snapshot()
            let playing = s.isPlaying
            let amp = Double(s.amplitude)
            let target = s.targetFrequency
            var freq = s.smoothedFrequency
            var phase = s.phase
            var pulsePos = s.pulsePosition

            for ch in 0..<buffers.count {
                guard let ptr = buffers[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                if !playing {
                    memset(ptr, 0, frames * MemoryLayout<Float>.size)
                }
            }
            if !playing {
                // Skip glide while silent so a long pause doesn't make the
                // next play a slow ramp from a stale midpoint.
                toneState.writeBack(smoothedFrequency: target, phase: phase, pulsePosition: 0)
                return noErr
            }

            // Synthesize into the first ENABLED channel, then copy/zero the
            // rest per the mask (per-ear presentation for the Listening
            // Check; both enabled = the Tone Finder's original behavior).
            let enabled: [Bool] = buffers.indices.map { ch in
                ch == 0 ? s.leftEnabled : (ch == 1 ? s.rightEnabled : false)
            }
            guard let scratchCh = enabled.firstIndex(of: true),
                  let scratchPtr = buffers[scratchCh].mData?.assumingMemoryBound(to: Float.self)
            else {
                toneState.writeBack(smoothedFrequency: freq, phase: phase, pulsePosition: pulsePos)
                return noErr
            }

            for i in 0..<frames {
                freq += (target - freq) * freqSmoothing
                // Pulse envelope: raised-cosine 5 ms edges around a 190 ms
                // hold, then 200 ms silence. Continuous mode = envelope 1.
                var env = 1.0
                if s.pulsing {
                    let pos = pulsePos % pulseCycleSamples
                    if pos >= pulseOnSamples {
                        env = 0
                    } else if pos < pulseRampSamples {
                        env = 0.5 * (1 - cos(Double.pi * Double(pos) / Double(pulseRampSamples)))
                    } else if pos >= pulseOnSamples - pulseRampSamples {
                        env = 0.5 * (1 - cos(Double.pi * Double(pulseOnSamples - pos) / Double(pulseRampSamples)))
                    }
                    pulsePos += 1
                }
                let sample = sin(phase) * amp * env
                scratchPtr[i] = Float(sample)
                phase += twoPi * freq / sr
                if phase > twoPi { phase -= twoPi }
            }
            for ch in buffers.indices where ch != scratchCh {
                guard let ptr = buffers[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                if enabled[ch] {
                    memcpy(ptr, scratchPtr, frames * MemoryLayout<Float>.size)
                } else {
                    memset(ptr, 0, frames * MemoryLayout<Float>.size)
                }
            }

            toneState.writeBack(smoothedFrequency: freq, phase: phase, pulsePosition: pulsePos)
            return noErr
        }

        self.sourceNode = node
        return node
    }

    func start() { isPlaying = true }
    func stop() { isPlaying = false }
    func toggle() { isPlaying.toggle() }
}
