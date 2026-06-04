import Foundation
import AVFoundation
import Combine
import os

/// Stereo-sample monitor for the vectorscope + analog VU views.
///
/// The audio tap callback runs on the render thread — we can't mutate
/// `@Published` properties from there without crossing Combine's main-
/// thread requirement. So `ingest` is a `nonisolated` fast path that
/// only memcpys into a lock-guarded staging buffer, and a 60-fps Timer
/// on the main thread drains the buffer and updates the published
/// state. That same Timer drives the needle physics.
final class StereoMonitor: ObservableObject {

    static let scopeSampleCount: Int = 512

    @Published private(set) var scopeSamples: [SamplePair]
    @Published private(set) var leftPeak: Float = 0
    @Published private(set) var rightPeak: Float = 0
    @Published private(set) var leftNeedle: Float = 0
    @Published private(set) var rightNeedle: Float = 0

    /// Raw per-tick RMS, linear (0…1). Republished every display tick
    /// even when the value is unchanged so downstream consumers driving
    /// their own ballistics (e.g. `AnalogVUMeter`) get a steady 60 Hz
    /// pulse rather than stalling on silent stretches. Distinct from
    /// `leftPeak` / `rightPeak`, which are already envelope-decayed and
    /// would double-smooth a proper VU integrator.
    @Published private(set) var leftRMS: Float = 0
    @Published private(set) var rightRMS: Float = 0

    struct SamplePair: Hashable {
        let l: Float
        let r: Float
    }

    private let needleTimeStep: Float = 1.0 / 60.0
    private let needleSpring: Float = 65
    private let needleDamping: Float = 16
    private var leftNeedleVelocity: Float = 0
    private var rightNeedleVelocity: Float = 0
    private var displayTimer: Timer?

    /// Staging buffer written by `ingest` (audio thread), drained by the
    /// display timer (main). Lock window is microseconds; both producer
    /// and consumer hold it only long enough to swap-out a small array.
    private let stagingLock = OSAllocatedUnfairLock<Staging>(
        initialState: Staging(samples: [], leftPeakLinear: 0, rightPeakLinear: 0)
    )
    private struct Staging {
        var samples: [SamplePair]
        var leftPeakLinear: Float
        var rightPeakLinear: Float
    }

    init() {
        scopeSamples = Array(
            repeating: SamplePair(l: 0, r: 0),
            count: Self.scopeSampleCount
        )
        // No auto-start. The 60 Hz display loop only runs while a Meters
        // view is actually on screen — see `subscribe()` / `unsubscribe()`.
        // Audio ingestion (`ingest`) keeps running regardless so the staging
        // buffer is always fresh when a Meters view appears.
    }

    /// Number of currently-attached views. Each `subscribe()` increments;
    /// each matching `unsubscribe()` decrements. The display loop runs iff
    /// this is > 0. Touched only from the main thread (SwiftUI lifecycle).
    private var subscriberCount: Int = 0

    /// Called from a Meters view's `.onAppear`. Spins up the 60 Hz display
    /// loop on first subscriber. Idempotent for additional subscribers.
    @MainActor
    func subscribe() {
        subscriberCount += 1
        if subscriberCount == 1, displayTimer == nil {
            startDisplayLoop()
        }
    }

    /// Called from a Meters view's `.onDisappear`. Tears down the display
    /// loop when the last subscriber leaves. Resets needle / peak state
    /// so a fresh attach starts from zero rather than stale values.
    @MainActor
    func unsubscribe() {
        guard subscriberCount > 0 else { return }
        subscriberCount -= 1
        if subscriberCount == 0 {
            displayTimer?.invalidate()
            displayTimer = nil
            // Clear physics state so the next attach starts cold.
            leftNeedleVelocity = 0
            rightNeedleVelocity = 0
        }
    }

    /// Last logged channel count from the audio tap. Logged once on change
    /// so the system Console shows whether the tap is delivering stereo
    /// (expected) or mono (would explain L≈R on the VU even when balance
    /// is offset). Touched only from the audio thread, no synchronisation
    /// needed since it's a single-writer Bool-like value.
    nonisolated(unsafe) private static var lastLoggedChannelCount: Int = 0
    private static let monitorLog = Logger(subsystem: "com.shawnbrown.AuditumEQ", category: "StereoMonitor")

    /// Called from the audio tap callback. Realtime-safe — bounded
    /// memcpy + one lock release. No `@Published` mutation here, so we
    /// don't trip Combine's "publishing from background thread" gate.
    nonisolated func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let chCount = Int(buffer.format.channelCount)
        if frames == 0 || chCount == 0 { return }

        // Diagnostic: log the channel count whenever it changes. If this
        // shows `1`, the mainMixer's output is mono and both VU bars
        // would necessarily read the same data — that's the most likely
        // explanation for L≈R on the meter regardless of balance.
        if chCount != Self.lastLoggedChannelCount {
            Self.lastLoggedChannelCount = chCount
            Self.monitorLog.info("StereoMonitor tap channel count = \(chCount)")
        }

        let left = channels[0]
        let right = chCount >= 2 ? channels[1] : channels[0]

        // Decimated trace for the vectorscope. Stride keeps the visible
        // shape stable across sample rates.
        let target = Self.scopeSampleCount
        let stride = max(1, frames / target)
        var pairs = [SamplePair](repeating: SamplePair(l: 0, r: 0), count: target)
        for i in 0..<target {
            let srcIdx = min(frames - 1, i * stride)
            pairs[i] = SamplePair(l: left[srcIdx], r: right[srcIdx])
        }

        // Per-buffer RMS over ALL frames — this is what a real VU meter
        // integrates, not the peak. Combined with the 60-fps envelope
        // smoothing it lands close to the canonical 300 ms VU response.
        var lSq: Float = 0
        var rSq: Float = 0
        for i in 0..<frames {
            lSq += left[i] * left[i]
            rSq += right[i] * right[i]
        }
        let invN = 1.0 / Float(frames)
        let lRMS = sqrt(lSq * invN)
        let rRMS = sqrt(rSq * invN)

        stagingLock.withLock { staging in
            staging.samples = pairs
            staging.leftPeakLinear = max(lRMS, staging.leftPeakLinear)
            staging.rightPeakLinear = max(rRMS, staging.rightPeakLinear)
        }
    }

    func reset() {
        scopeSamples = Array(
            repeating: SamplePair(l: 0, r: 0),
            count: Self.scopeSampleCount
        )
        leftPeak = 0; rightPeak = 0
        leftRMS = 0; rightRMS = 0
        leftNeedle = 0; rightNeedle = 0
        leftNeedleVelocity = 0; rightNeedleVelocity = 0
        stagingLock.withLock { staging in
            staging = Staging(samples: [], leftPeakLinear: 0, rightPeakLinear: 0)
        }
    }

    private func startDisplayLoop() {
        // Schedule on RunLoop.main in .common mode so the timer keeps
        // firing during UI event tracking (slider drags, scroll, etc.).
        // `Timer.scheduledTimer` attaches to *current* runloop in
        // .default mode, which can mean nothing during App init.
        let timer = Timer(timeInterval: TimeInterval(needleTimeStep), repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    /// Drain the staging buffer and publish on main. Combine sees the
    /// `@Published` set happen on the main thread because the Timer
    /// fires on the runloop it was scheduled on (main).
    private func tick() {
        let snapshot = stagingLock.withLock { staging -> Staging in
            let s = staging
            // Reset peak inside the lock so the next audio tick can
            // observe a fresh max. Decay is folded in below.
            staging.leftPeakLinear = 0
            staging.rightPeakLinear = 0
            return s
        }

        if !snapshot.samples.isEmpty {
            scopeSamples = snapshot.samples
        }
        // Per-tick RMS for `AnalogVUMeter`'s ballistics. The audio tap
        // delivers ~21 ms buffers (1024 frames @ 48 kHz) while this
        // timer fires every ~16.7 ms — so on roughly 22 % of ticks no
        // new buffer has arrived and `snapshot.leftPeakLinear` is 0.
        // A naïve assignment would crash the VU integrator's target
        // to the floor on every gap and pin the needle at −∞ during
        // normal playback. Hold the previous reading with a gentle
        // per-tick decay so single-tick gaps don't bounce to zero but
        // real silence still drains away within a couple of frames.
        let kHoldDecay: Float = 0.85
        if snapshot.leftPeakLinear > 0 {
            leftRMS = snapshot.leftPeakLinear
        } else {
            leftRMS = leftRMS * kHoldDecay
        }
        if snapshot.rightPeakLinear > 0 {
            rightRMS = snapshot.rightPeakLinear
        } else {
            rightRMS = rightRMS * kHoldDecay
        }
        // Attack-fast / release-slow envelope on the peak.
        leftPeak = max(snapshot.leftPeakLinear, leftPeak * 0.85)
        rightPeak = max(snapshot.rightPeakLinear, rightPeak * 0.85)

        // Needle physics (mass-spring-damper, mass = 1).
        let lTarget = vuPosition(forLinear: leftPeak)
        let rTarget = vuPosition(forLinear: rightPeak)
        let lAccel = needleSpring * (lTarget - leftNeedle) - needleDamping * leftNeedleVelocity
        let rAccel = needleSpring * (rTarget - rightNeedle) - needleDamping * rightNeedleVelocity
        leftNeedleVelocity += lAccel * needleTimeStep
        rightNeedleVelocity += rAccel * needleTimeStep
        leftNeedle = max(0, min(1.1, leftNeedle + leftNeedleVelocity * needleTimeStep))
        rightNeedle = max(0, min(1.1, rightNeedle + rightNeedleVelocity * needleTimeStep))
    }

    /// Map linear RMS (0…1) to dial position (0 … 1.05).
    ///
    /// Calibrated for *consumer playback*, not broadcast. Real VU at
    /// 0 VU = -20 dBFS was meant for a +4 dBu nominal pro line level
    /// peaking around -10 dBFS — modern mastered music is mixed much
    /// hotter (typical RMS -14 to -10 dBFS, peaks slamming 0 dBFS).
    /// Reading consumer output against the broadcast reference pegs the
    /// meter on anything louder than a whisper.
    ///
    /// Map (dBFS RMS):
    ///   -40 → 0 (far left, ≈ silence)
    ///   -20 → 0.5 (mid-scale, "0 VU" engraving area)
    ///    -3 → 0.93 (well into red)
    ///     0 → 1.05 (peg)
    private func vuPosition(forLinear v: Float) -> Float {
        if v < 1e-6 { return 0 }
        let db = 20 * log10(v)
        let normalized = (db + 40) / 40
        return max(0, min(1.05, normalized))
    }
}
