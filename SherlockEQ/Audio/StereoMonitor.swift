import Foundation
import AppKit
import AVFoundation
import Combine
import os

/// Stereo-level monitor for the digital + analog VU views.
///
/// The audio tap callback runs on the render thread — we can't mutate
/// `@Published` properties from there without crossing Combine's main-
/// thread requirement. So `ingest` is a `nonisolated` fast path that
/// only stores per-buffer RMS into a lock-guarded staging slot, and a
/// 60-fps Timer on the main thread drains it and updates the published
/// state.
final class StereoMonitor: ObservableObject {

    @Published private(set) var leftPeak: Float = 0
    @Published private(set) var rightPeak: Float = 0

    /// Raw per-tick RMS, linear (0…1), on its **own** observable object.
    ///
    /// These republish every display tick even when the value is unchanged, so
    /// consumers driving their own ballistics (`AnalogVUMeter`) get a steady
    /// 60 Hz pulse rather than stalling on silent stretches. Distinct from
    /// `leftPeak` / `rightPeak`, which are already envelope-decayed and would
    /// double-smooth a proper VU integrator.
    ///
    /// They live on a nested object rather than on `StereoMonitor` because
    /// `ObservableObject` invalidation is object-wide, not per-property: while
    /// these sat here, that deliberate 60 Hz pulse woke **every** observer —
    /// including `DigitalLRMeter` and `PopoverLevelStrip`, which read only the
    /// peaks and had nothing to redraw. Silence still cost a full meter
    /// re-render 120 times a second. Now only the VU meter subscribes to the
    /// pulse, and gating the peaks (see `tick`) actually lets the digital
    /// meters go idle.
    let rms = RMSClock()

    /// The 60 Hz pulse, isolated so subscribing to it is opt-in.
    final class RMSClock: ObservableObject {
        @Published fileprivate(set) var leftRMS: Float = 0
        @Published fileprivate(set) var rightRMS: Float = 0
    }

    private let displayTimeStep: Float = 1.0 / 60.0
    private var displayTimer: Timer?

    /// Staging slot written by `ingest` (audio thread), drained by the
    /// display timer (main). Lock window is nanoseconds — two Float
    /// max-stores on the producer side, a copy-and-reset on the consumer.
    private let stagingLock = OSAllocatedUnfairLock<Staging>(
        initialState: Staging(leftPeakLinear: 0, rightPeakLinear: 0)
    )
    private struct Staging {
        var leftPeakLinear: Float
        var rightPeakLinear: Float
        /// Channel count waiting to be logged (nil = nothing pending).
        /// `ingest` runs on the render thread, where os_log formats and
        /// crosses into logd — not allocation/latency safe (audit RT-04) —
        /// so it stages the value here and the display tick emits it.
        var pendingChannelCountLog: Int? = nil
    }

    init() {
        installScreenSleepObservers()
        // No auto-start. The 60 Hz display loop only runs while a VU
        // view is actually on screen — see `subscribe()` / `unsubscribe()`.
        // Audio ingestion (`ingest`) keeps running regardless so the staging
        // slot is always fresh when a VU view appears.
    }

    deinit {
        if let t = screensDidSleepToken {
            NSWorkspace.shared.notificationCenter.removeObserver(t)
        }
        if let t = screensDidWakeToken {
            NSWorkspace.shared.notificationCenter.removeObserver(t)
        }
    }

    /// Number of currently-attached views. Each `subscribe()` increments;
    /// each matching `unsubscribe()` decrements. The display loop runs iff
    /// this is > 0. Touched only from the main thread (SwiftUI lifecycle).
    private var subscriberCount: Int = 0

    /// Tracks whether the displays are currently lit. When false (Mac
    /// is locked / display sleep / clamshell) the 60 Hz display loop is
    /// paused even with subscribers present — Combine would otherwise
    /// keep publishing to views that nothing is drawing, burning
    /// laptop battery for no visible effect.
    private var screensAwake: Bool = true
    private var screensDidSleepToken: NSObjectProtocol?
    private var screensDidWakeToken: NSObjectProtocol?

    private func installScreenSleepObservers() {
        let center = NSWorkspace.shared.notificationCenter
        screensDidSleepToken = center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreensSlept() }
        }
        screensDidWakeToken = center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreensWoke() }
        }
    }

    @MainActor
    private func handleScreensSlept() {
        screensAwake = false
        // Tear down the timer without touching subscriberCount — when
        // the user wakes the display, screensDidWake restarts it iff
        // someone's still subscribed.
        displayTimer?.invalidate()
        displayTimer = nil
    }

    @MainActor
    private func handleScreensWoke() {
        screensAwake = true
        if subscriberCount > 0, displayTimer == nil {
            startDisplayLoop()
        }
    }

    /// Called from a VU view's `.onAppear`. Spins up the 60 Hz display
    /// loop on first subscriber. Idempotent for additional subscribers.
    @MainActor
    func subscribe() {
        subscriberCount += 1
        if subscriberCount == 1, displayTimer == nil, screensAwake {
            startDisplayLoop()
        }
    }

    /// Called from a VU view's `.onDisappear`. Tears down the display
    /// loop when the last subscriber leaves.
    @MainActor
    func unsubscribe() {
        guard subscriberCount > 0 else { return }
        subscriberCount -= 1
        if subscriberCount == 0 {
            displayTimer?.invalidate()
            displayTimer = nil
        }
    }

    /// Last logged channel count from the audio tap. Logged once on change
    /// so the system Console shows whether the tap is delivering stereo
    /// (expected) or mono (would explain L≈R on the VU even when balance
    /// is offset). Behind an unfair lock — single-writer in practice, but
    /// `nonisolated(unsafe)` papered over the fact that multiple StereoMonitor
    /// instances could share writers, and Swift 6 strict-concurrency wants
    /// the contract spelled out.
    nonisolated private static let lastLoggedChannelCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    nonisolated private static let monitorLog = Logger(subsystem: "com.shawnbrown.SherlockEQ", category: "StereoMonitor")

    /// Called from the audio tap callback. Realtime-safe — a bounded RMS
    /// loop + one brief lock. No `@Published` mutation here, so we don't
    /// trip Combine's "publishing from background thread" gate.
    nonisolated func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let chCount = Int(buffer.format.channelCount)
        if frames == 0 || chCount == 0 { return }

        // Diagnostic: log the channel count whenever it changes. If this
        // shows `1`, the mainMixer's output is mono and both VU bars
        // would necessarily read the same data — that's the most likely
        // explanation for L≈R on the meter regardless of balance.
        // Check-and-set under the lock so the "changed?" decision and
        // the update happen atomically across threads.
        let changed = Self.lastLoggedChannelCount.withLock { stored -> Bool in
            guard stored != chCount else { return false }
            stored = chCount
            return true
        }
        if changed {
            // Stage rather than log: see Staging.pendingChannelCountLog.
            // The message lands on the next display tick — i.e. while a
            // meter is on screen, which is exactly when someone is looking
            // at an L≈R mystery this diagnostic exists for.
            stagingLock.withLock { $0.pendingChannelCountLog = chCount }
        }

        let left = channels[0]
        let right = chCount >= 2 ? channels[1] : channels[0]

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
            staging.leftPeakLinear = max(lRMS, staging.leftPeakLinear)
            staging.rightPeakLinear = max(rRMS, staging.rightPeakLinear)
        }
    }

    func reset() {
        leftPeak = 0; rightPeak = 0
        rms.leftRMS = 0; rms.rightRMS = 0
        stagingLock.withLock { staging in
            staging.leftPeakLinear = 0
            staging.rightPeakLinear = 0
        }
    }

    private func startDisplayLoop() {
        // Schedule on RunLoop.main in .common mode so the timer keeps
        // firing during UI event tracking (slider drags, scroll, etc.).
        // `Timer.scheduledTimer` attaches to *current* runloop in
        // .default mode, which can mean nothing during App init.
        let timer = Timer(timeInterval: TimeInterval(displayTimeStep), repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    /// Drain the staging slot and publish on main. Combine sees the
    /// `@Published` set happen on the main thread because the Timer
    /// fires on the runloop it was scheduled on (main).
    private func tick() {
        let (lPeak, rPeak, pendingLog): (Float, Float, Int?) = stagingLock.withLock { staging in
            let copy = (staging.leftPeakLinear, staging.rightPeakLinear, staging.pendingChannelCountLog)
            // Reset peaks inside the lock so the next audio tick can
            // observe a fresh max.
            staging.leftPeakLinear = 0
            staging.rightPeakLinear = 0
            staging.pendingChannelCountLog = nil
            return copy
        }
        // Deferred from ingest (render thread) — emit outside the lock.
        if let chCount = pendingLog {
            Self.monitorLog.info("StereoMonitor tap channel count = \(chCount)")
        }

        // Per-tick RMS for `AnalogVUMeter`'s ballistics. The audio tap
        // delivers ~21 ms buffers (1024 frames @ 48 kHz) while this
        // timer fires every ~16.7 ms — so on roughly 22 % of ticks no
        // new buffer has arrived and the drained peak is 0. A naïve
        // assignment would crash the VU integrator's target to the
        // floor on every gap and pin the needle at −∞ during normal
        // playback. Hold the previous reading with a gentle per-tick
        // decay so single-tick gaps don't bounce to zero but real
        // silence still drains away within a couple of frames.
        let kHoldDecay: Float = 0.85
        if lPeak > 0 {
            rms.leftRMS = lPeak
        } else {
            rms.leftRMS = rms.leftRMS * kHoldDecay
        }
        if rPeak > 0 {
            rms.rightRMS = rPeak
        } else {
            rms.rightRMS = rms.rightRMS * kHoldDecay
        }
        // Attack-fast / release-slow envelope on the peak.
        //
        // Written only when the value actually moved. `@Published` performs no
        // equality check — every assignment emits `objectWillChange` — so the
        // previous unconditional pair kept publishing right through silence,
        // where the decay multiply only ever produced another value nobody
        // could tell apart, re-rendering `DigitalLRMeter` and
        // `PopoverLevelStrip` 120 times a second for no visible change.
        //
        // The `leftRMS` / `rightRMS` writes above stay unconditional on
        // purpose: `AnalogVUMeter` documents its dependence on that steady
        // 60 Hz pulse to drive its own ballistics, and gating it would stall
        // the needle on silent stretches. Only the peaks — which are already
        // envelope-decayed here — can be gated.
        let nextLeft = Self.nextPeak(current: leftPeak, incoming: lPeak)
        if Self.visiblyDiffers(leftPeak, nextLeft) { leftPeak = nextLeft }
        let nextRight = Self.nextPeak(current: rightPeak, incoming: rPeak)
        if Self.visiblyDiffers(rightPeak, nextRight) { rightPeak = nextRight }
    }

    // MARK: - Peak envelope

    /// Per-tick release factor for the peak envelope.
    private static let peakDecay: Float = 0.85

    /// Below this the meters already read their −60 dBFS floor, so the decay
    /// tail is snapped to zero instead of approaching it forever. Without the
    /// snap a silent input never reaches a fixed point and the gate below
    /// never latches.
    private static let peakFloor: Float = 1e-5

    /// Smallest movement worth republishing. 0.2 % linear is ~0.017 dB, which
    /// is well under one pixel on a 180 pt bar spanning 60 dB.
    private static let peakRelativeEpsilon: Float = 0.002

    private static func nextPeak(current: Float, incoming: Float) -> Float {
        let next = max(incoming, current * peakDecay)
        return next < peakFloor ? 0 : next
    }

    private static func visiblyDiffers(_ old: Float, _ new: Float) -> Bool {
        abs(new - old) > max(1e-6, abs(old) * peakRelativeEpsilon)
    }
}
