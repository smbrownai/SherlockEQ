import Foundation
import os

/// Lock-guarded biquad cascade for AVAudioSourceNode render-block use.
///
/// Replaces the per-ear `AVAudioUnitEQ` AutoEQ stage. The AU's stereo
/// processing was reintroducing cross-channel content under extreme
/// balance pans — even though our source nodes guarantee mono-on-one-
/// channel input, ~−50 dB of the L signal would land on the R bus at
/// the post-EQ tap. Processing the same biquad cascade by hand on a
/// single Float buffer per render block keeps the L and R signal paths
/// physically separate, so a muted bus stays truly muted.
///
/// Lifecycle:
///   - The host (CATapEngine) owns one instance per ear.
///   - The audio render thread calls `process(samples:count:)` once per
///     buffer, on the channel that holds real signal.
///   - The main thread reconfigures the cascade via `setBands(...)` and
///     can quickly toggle `setBypassed(_:)` for Reference Mode.
///   - Coefficient updates are picked up on the render block's next
///     call — no glitch beyond the natural impulse response of the new
///     filter set.
///
/// Realtime safety: the audio thread acquires the unfair lock once per
/// buffer to snapshot the current coefficient set (Array COW makes this
/// O(1)). Critical sections are microseconds and contention is rare
/// (only profile changes write). Same pattern as `StereoMonitor.staging`
/// — established as fine for short critical sections in this codebase.
final class BiquadCascade {

    /// Normalised biquad coefficients (a0 factored out, so the
    /// recurrence on the audio thread is just five multiplies + four
    /// adds per sample per section). Direct-form II transposed.
    struct Section {
        var b0: Float = 1
        var b1: Float = 0
        var b2: Float = 0
        var a1: Float = 0
        var a2: Float = 0
    }

    private struct CoefficientState {
        var sections: [Section] = []
        var preGain: Float = 1
        var bypassed: Bool = false
    }

    private let stateLock = OSAllocatedUnfairLock<CoefficientState>(
        initialState: CoefficientState()
    )

    /// Per-section storage taps (z1, z2) for the single channel this
    /// cascade processes. Touched only from the audio render thread, so
    /// no synchronisation. Sized to match the current section count;
    /// reallocated on coefficient changes and zeroed at that time so
    /// state doesn't blow up against the new filter set.
    private var z1: [Float] = []
    private var z2: [Float] = []
    private var stateSectionCount: Int = 0

    init() {}

    // MARK: - Configuration (main thread)

    /// Reconfigure with a new set of EQ bands and pre-gain. Safe to
    /// call any time; the audio thread picks up the new coefficients
    /// on its next render block call. Pass `[]` for bands to make the
    /// cascade pure pre-gain (or, with preampDB == 0, identity).
    func setBands(_ bands: [EQBand], preampDB: Double, sampleRate: Double) {
        // Build immutably so the `withLock` closure captures by value
        // rather than by reference (Swift 6 strict-concurrency clean).
        let sections: [Section] = bands.compactMap {
            Self.makeSection(for: $0, sampleRate: sampleRate)
        }
        let preGain = Float(pow(10.0, preampDB / 20.0))
        stateLock.withLock { state in
            state.sections = sections
            state.preGain = preGain
        }
    }

    /// Toggle bypass without losing coefficients. Used by Reference
    /// Mode — when re-enabled, processing resumes with the previously
    /// configured bands without needing applyProfile to re-run.
    func setBypassed(_ on: Bool) {
        stateLock.withLock { $0.bypassed = on }
    }

    // MARK: - Processing (audio thread)

    /// Filter `count` samples in-place. Called from the audio render
    /// thread. Single channel per instance — the host wires one
    /// `BiquadCascade` to the L channel of `leftSourceNode`'s render
    /// block, and a separate one to the R channel of `rightSourceNode`'s.
    func process(samples: UnsafeMutablePointer<Float>, count: Int) {
        // Snapshot the current coefficients. Array COW keeps this O(1)
        // — we don't copy the underlying buffer, just bump a ref count.
        let snapshot = stateLock.withLock { $0 }
        if snapshot.bypassed { return }

        let nSections = snapshot.sections.count
        let preGain = snapshot.preGain

        // Ensure per-section state buffers match the current count.
        // Reallocates + zeros on change; steady-state is alloc-free.
        if nSections != stateSectionCount {
            z1 = Array(repeating: 0, count: nSections)
            z2 = Array(repeating: 0, count: nSections)
            stateSectionCount = nSections
        }

        // Fast path: zero sections → pure pre-gain (no-op if preGain==1).
        if nSections == 0 {
            if preGain != 1 {
                for i in 0..<count { samples[i] *= preGain }
            }
            return
        }

        // Direct-form II transposed cascade — minimum-precision per
        // section, but on Float32 audio at 48 kHz that's fine for the
        // ±12 dB band gains AutoEQ typically uses.
        snapshot.sections.withUnsafeBufferPointer { sBuf in
            z1.withUnsafeMutableBufferPointer { z1Buf in
                z2.withUnsafeMutableBufferPointer { z2Buf in
                    for i in 0..<count {
                        var x = samples[i] * preGain
                        for k in 0..<nSections {
                            let s = sBuf[k]
                            let y = s.b0 * x + z1Buf[k]
                            z1Buf[k] = s.b1 * x - s.a1 * y + z2Buf[k]
                            z2Buf[k] = s.b2 * x - s.a2 * y
                            x = y
                        }
                        samples[i] = x
                    }
                }
            }
        }
    }

    // MARK: - Coefficient calculation

    /// Audio EQ Cookbook coefficients normalised by a0. Mirrors the
    /// math in `BiquadResponse` (which keeps its own private copy for
    /// the frequency-response curve drawing). Returns nil for an
    /// identity band so the cascade stays as short as possible.
    private static func makeSection(for band: EQBand, sampleRate: Double) -> Section? {
        // Disabled bands → identity, drop.
        if !band.enabled { return nil }
        // Skip flat parametric / shelf bands — identity, no need to
        // pay for filter state. Notch / band-pass / low-pass / high-pass
        // bands still have an effect at 0 dB.
        let isShape = band.filterType == .notch
            || band.filterType == .bandPass
            || band.filterType == .lowPass
            || band.filterType == .highPass
        if !isShape, band.gaindB == 0 { return nil }

        let f0 = max(20.0, min(sampleRate / 2 - 1, band.frequencyHz))
        let A = pow(10.0, band.gaindB / 40.0)
        let w0 = 2.0 * .pi * f0 / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let Q = max(0.1, band.bandwidth)
        let alpha = sinW0 / (2.0 * Q)
        let sqrtA = A.squareRoot()
        let twoSqrtAalpha = 2.0 * sqrtA * alpha

        let b0d, b1d, b2d, a0d, a1d, a2d: Double
        switch band.filterType {
        case .parametric:
            b0d = 1 + alpha * A
            b1d = -2 * cosW0
            b2d = 1 - alpha * A
            a0d = 1 + alpha / A
            a1d = -2 * cosW0
            a2d = 1 - alpha / A
        case .lowShelf:
            b0d = A * ((A + 1) - (A - 1) * cosW0 + twoSqrtAalpha)
            b1d = 2 * A * ((A - 1) - (A + 1) * cosW0)
            b2d = A * ((A + 1) - (A - 1) * cosW0 - twoSqrtAalpha)
            a0d = (A + 1) + (A - 1) * cosW0 + twoSqrtAalpha
            a1d = -2 * ((A - 1) + (A + 1) * cosW0)
            a2d = (A + 1) + (A - 1) * cosW0 - twoSqrtAalpha
        case .highShelf:
            b0d = A * ((A + 1) + (A - 1) * cosW0 + twoSqrtAalpha)
            b1d = -2 * A * ((A - 1) + (A + 1) * cosW0)
            b2d = A * ((A + 1) + (A - 1) * cosW0 - twoSqrtAalpha)
            a0d = (A + 1) - (A - 1) * cosW0 + twoSqrtAalpha
            a1d = 2 * ((A - 1) - (A + 1) * cosW0)
            a2d = (A + 1) - (A - 1) * cosW0 - twoSqrtAalpha
        case .notch:
            b0d = 1
            b1d = -2 * cosW0
            b2d = 1
            a0d = 1 + alpha
            a1d = -2 * cosW0
            a2d = 1 - alpha
        case .bandPass:
            b0d = alpha
            b1d = 0
            b2d = -alpha
            a0d = 1 + alpha
            a1d = -2 * cosW0
            a2d = 1 - alpha
        case .lowPass:
            b0d = (1 - cosW0) / 2
            b1d = 1 - cosW0
            b2d = (1 - cosW0) / 2
            a0d = 1 + alpha
            a1d = -2 * cosW0
            a2d = 1 - alpha
        case .highPass:
            b0d = (1 + cosW0) / 2
            b1d = -(1 + cosW0)
            b2d = (1 + cosW0) / 2
            a0d = 1 + alpha
            a1d = -2 * cosW0
            a2d = 1 - alpha
        }

        guard a0d != 0 else { return nil }
        var s = Section()
        s.b0 = Float(b0d / a0d)
        s.b1 = Float(b1d / a0d)
        s.b2 = Float(b2d / a0d)
        s.a1 = Float(a1d / a0d)
        s.a2 = Float(a2d / a0d)
        return s
    }
}
