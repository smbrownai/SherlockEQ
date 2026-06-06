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

    /// Hard ceiling on per-cascade biquad sections. AutoEQ + profile +
    /// notch chains typically run <20 active bands; 64 sits well past
    /// any realistic ceiling. `setBands` truncates beyond this.
    static let maxSections: Int = 64

    /// Per-section storage taps (z1, z2) for the single channel this
    /// cascade processes. Touched only from the audio render thread, so
    /// no synchronisation. Pre-allocated to `maxSections` so a profile
    /// change never triggers a heap allocation on the audio thread —
    /// the render block just memsets the active prefix when the section
    /// count changes.
    private var z1: [Float] = Array(repeating: 0, count: BiquadCascade.maxSections)
    private var z2: [Float] = Array(repeating: 0, count: BiquadCascade.maxSections)
    private var stateSectionCount: Int = 0

    init() {}

    // MARK: - Configuration (main thread)

    /// Reconfigure with a new set of EQ bands and pre-gain. Safe to
    /// call any time; the audio thread picks up the new coefficients
    /// on its next render block call. Pass `[]` for bands to make the
    /// cascade pure pre-gain (or, with preampDB == 0, identity).
    func setBands(_ bands: [EQBand], preampDB: Double, sampleRate: Double) {
        // Build into a `let` so the `withLock` closure (which is `@Sendable`)
        // captures by value — Swift 6 strict-concurrency forbids `@Sendable`
        // capture of `var`. Cap at `maxSections` so the audio thread's
        // preallocated state buffers can't be over-run — any band beyond
        // the cap is silently dropped (an unrealistic case in practice;
        // see maxSections docs).
        let mapped: [Section] = bands.compactMap {
            Self.makeSection(for: $0, sampleRate: sampleRate)
        }
        let sections: [Section] = mapped.count > Self.maxSections
            ? Array(mapped.prefix(Self.maxSections))
            : mapped
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

        // On section count change, zero the active prefix of z1/z2 so
        // stale state from a longer (or different-shape) cascade can't
        // leak into the new filter set. Tail indices past nSections are
        // never read, so they don't need clearing. The buffers are
        // pre-allocated to `maxSections` at init — no heap work here.
        if nSections != stateSectionCount {
            let clearCount = max(nSections, stateSectionCount)
            z1.withUnsafeMutableBufferPointer { buf in
                if let base = buf.baseAddress {
                    memset(base, 0, clearCount * MemoryLayout<Float>.size)
                }
            }
            z2.withUnsafeMutableBufferPointer { buf in
                if let base = buf.baseAddress {
                    memset(base, 0, clearCount * MemoryLayout<Float>.size)
                }
            }
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

    /// Build a normalised filter section for one band, or nil if the
    /// band reduces to identity (so the cascade stays as short as
    /// possible). Cookbook math lives in `BiquadCoefficients` — shared
    /// with `BiquadResponse` so the drawn curve can't disagree with the
    /// processed audio.
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

        let c = BiquadCoefficients.cookbook(for: band, sampleRate: sampleRate)
        guard c.a0 != 0 else { return nil }
        var s = Section()
        s.b0 = Float(c.b0 / c.a0)
        s.b1 = Float(c.b1 / c.a0)
        s.b2 = Float(c.b2 / c.a0)
        s.a1 = Float(c.a1 / c.a0)
        s.a2 = Float(c.a2 / c.a0)
        return s
    }
}
