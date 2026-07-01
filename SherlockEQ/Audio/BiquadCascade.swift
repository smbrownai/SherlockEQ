import Foundation
import Accelerate
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
/// The per-section recurrence runs on Accelerate's `vDSP_biquad` (a
/// vectorised Direct-Form II cascade) rather than a hand-written scalar
/// loop — Apple maintains the SIMD kernel, and it keeps our per-ear
/// separation intact because each ear drives its own `BiquadCascade`
/// (and therefore its own setup + delay state). `vDSP_biquad` allocates
/// a "setup" object for its coefficients, so we wrap that in `Filter` and
/// let ARC manage its lifetime exactly like the old `[Section]` array did:
/// the setup is built on the main thread in `setBands`, the audio thread
/// only ever snapshots a reference under the lock, and the setup is
/// destroyed when the last reference drops — no free on the hot path
/// except the rare in-flight buffer straddling a profile change, which is
/// the same threading profile the array snapshot already had.
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
/// buffer to snapshot the current filter (a reference + two floats, O(1)).
/// Critical sections are microseconds and contention is rare (only profile
/// changes write). The delay buffer is pre-allocated to `maxSections`, so a
/// profile change never allocates on the audio thread.
final class BiquadCascade {

    /// Number of coefficients `vDSP_biquad` expects per section, in the
    /// order it reads them: b0, b1, b2, a1, a2 (a0 normalised to 1).
    private static let coeffsPerSection = 5

    /// Wraps a `vDSP_biquad` setup so ARC owns its lifetime. Immutable after
    /// init (both stored properties are `let`), so it's safe to hand across
    /// to the audio thread — hence `@unchecked Sendable`.
    private final class Filter: @unchecked Sendable {
        let setup: vDSP_biquad_Setup
        let sectionCount: Int

        /// `coefficients` holds `5 * sectionCount` doubles in vDSP order.
        /// Returns nil if the setup can't be created (e.g. zero sections).
        init?(coefficients: [Double], sectionCount: Int) {
            guard sectionCount > 0,
                  let setup = vDSP_biquad_CreateSetup(coefficients, vDSP_Length(sectionCount))
            else { return nil }
            self.setup = setup
            self.sectionCount = sectionCount
        }

        deinit { vDSP_biquad_DestroySetup(setup) }
    }

    private struct CoefficientState {
        var filter: Filter?      // nil ⇒ no active sections (pure pre-gain)
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

    /// Delay/state buffer for `vDSP_biquad`. The call needs `2*M + 2` floats
    /// for an `M`-section cascade, preserved across calls. Pre-allocated to
    /// the max so a profile change never triggers a heap allocation on the
    /// audio thread — the render block just zeroes the active prefix when the
    /// section count changes. Touched only from the audio render thread.
    private var delays: [Float] = Array(
        repeating: 0, count: 2 * BiquadCascade.maxSections + 2
    )
    private var stateSectionCount: Int = 0

    init() {}

    // MARK: - Configuration (main thread)

    /// Reconfigure with a new set of EQ bands and pre-gain. Safe to
    /// call any time; the audio thread picks up the new coefficients
    /// on its next render block call. Pass `[]` for bands to make the
    /// cascade pure pre-gain (or, with preampDB == 0, identity).
    func setBands(_ bands: [EQBand], preampDB: Double, sampleRate: Double) {
        // Flatten each non-identity band into vDSP's [b0,b1,b2,a1,a2] layout.
        // Cap at `maxSections` so the audio thread's preallocated delay buffer
        // can't be over-run — any band beyond the cap is silently dropped (an
        // unrealistic case in practice; see maxSections docs).
        var coefficients: [Double] = []
        coefficients.reserveCapacity(bands.count * Self.coeffsPerSection)
        var sectionCount = 0
        for band in bands {
            guard sectionCount < Self.maxSections,
                  let c = Self.normalizedSection(for: band, sampleRate: sampleRate)
            else { continue }
            coefficients.append(c.b0)
            coefficients.append(c.b1)
            coefficients.append(c.b2)
            coefficients.append(c.a1)
            coefficients.append(c.a2)
            sectionCount += 1
        }

        // Build the setup here, on the main thread, so the audio thread never
        // allocates. nil when there are no sections (pure pre-gain path).
        let filter = sectionCount > 0
            ? Filter(coefficients: coefficients, sectionCount: sectionCount)
            : nil
        // Defense-in-depth: callers (parsers, profile decode) are expected to
        // have already clamped preampDB, but this is the last stop before the
        // render thread multiplies raw samples by preGain — an unclamped or
        // non-finite value here would reach the audio output directly.
        let clampedPreampDB = preampDB.isFinite
            ? max(-BiquadCoefficients.gainClampDB, min(BiquadCoefficients.gainClampDB, preampDB))
            : 0
        let preGain = Float(pow(10.0, clampedPreampDB / 20.0))
        stateLock.withLock { state in
            state.filter = filter
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
        // Snapshot the current filter. Copying the struct retains the Filter
        // reference (O(1)); the setup stays alive for this call even if the
        // main thread swaps in a new one mid-buffer.
        let snapshot = stateLock.withLock { $0 }
        if snapshot.bypassed { return }

        var preGain = snapshot.preGain

        // Pre-gain pass (vectorised). Skipped when unity to save a pass.
        if preGain != 1 {
            vDSP_vsmul(samples, 1, &preGain, samples, 1, vDSP_Length(count))
        }

        // No active sections → pure pre-gain (already applied above).
        guard let filter = snapshot.filter else { return }
        let nSections = filter.sectionCount

        // On section-count change, zero the active delay prefix (2*M + 2) so
        // stale state from a longer (or different-shape) cascade can't leak
        // into the new filter set. Indices past the prefix are never read.
        if nSections != stateSectionCount {
            let usedNow = 2 * nSections + 2
            let usedBefore = 2 * stateSectionCount + 2
            let clearCount = max(usedNow, usedBefore)
            delays.withUnsafeMutableBufferPointer { buf in
                if let base = buf.baseAddress {
                    memset(base, 0, clearCount * MemoryLayout<Float>.size)
                }
            }
            stateSectionCount = nSections
        }

        // Run the cascade in place. vDSP_biquad evaluates the standard
        // normalised recurrence per section:
        //   y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] − a1·y[n-1] − a2·y[n-2]
        // which is exactly the cookbook coefficients we pass (a0 factored out).
        delays.withUnsafeMutableBufferPointer { delayBuf in
            guard let delayBase = delayBuf.baseAddress else { return }
            vDSP_biquad(filter.setup, delayBase,
                        samples, 1,
                        samples, 1,
                        vDSP_Length(count))

            // Denormal flush. Float32 IIR state can drift into denormal range
            // during long silent fade-outs; on x86_64 each denormal op traps
            // to microcode (30–100× slowdown). Apple Silicon is full-speed in
            // hardware, but flushing the active delay prefix once per buffer
            // (O(nSections), not O(count)) keeps the cascade safe on Intel.
            let denormalThreshold: Float = 1e-25
            let used = 2 * nSections + 2
            for k in 0..<used where abs(delayBase[k]) < denormalThreshold {
                delayBase[k] = 0
            }
        }
    }

    // MARK: - Coefficient calculation

    /// Build a normalised filter section (a0 factored out) for one band, or
    /// nil if the band reduces to identity (so the cascade stays as short as
    /// possible). Cookbook math lives in `BiquadCoefficients` — shared with
    /// `BiquadResponse` so the drawn curve can't disagree with the processed
    /// audio.
    private static func normalizedSection(
        for band: EQBand, sampleRate: Double
    ) -> (b0: Double, b1: Double, b2: Double, a1: Double, a2: Double)? {
        // Disabled bands → identity, drop.
        if !band.enabled { return nil }
        // Skip flat parametric / shelf bands — identity, no need to pay for
        // filter state. Notch / band-pass / low-pass / high-pass bands still
        // have an effect at 0 dB.
        let isShape = band.filterType == .notch
            || band.filterType == .bandPass
            || band.filterType == .lowPass
            || band.filterType == .highPass
        if !isShape, band.gaindB == 0 { return nil }

        let c = BiquadCoefficients.cookbook(for: band, sampleRate: sampleRate)
        guard c.a0 != 0 else { return nil }
        return (
            b0: c.b0 / c.a0,
            b1: c.b1 / c.a0,
            b2: c.b2 / c.a0,
            a1: c.a1 / c.a0,
            a2: c.a2 / c.a0
        )
    }
}
