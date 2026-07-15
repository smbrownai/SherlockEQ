import Foundation
import Combine
import AppKit

/// Display-rate telemetry for the Adaptive Correction stage's live
/// per-band gains (phase4-adaptive-correction.md §6.2) — the moving half
/// of "drawn = heard". Polls the six `AudioCounter` values on each ear's
/// `AdaptiveCorrectionProcessor` at ~15 Hz and republishes them as dB.
///
/// Mirrors `DynamicActivityMonitor` exactly: a small dedicated
/// `ObservableObject` observed directly by the canvas overlay (never
/// rebroadcast through `AudioState` — the 46 Hz lesson), with a
/// subscriber-refcounted poll loop that pauses on display sleep.
@MainActor
final class AdaptiveActivityMonitor: ObservableObject {

    /// Current applied gain per filterbank band (dB), one array per ear.
    @Published private(set) var leftGainsDB: [Double] = AdaptiveActivityMonitor.idle
    @Published private(set) var rightGainsDB: [Double] = AdaptiveActivityMonitor.idle

    private static let idle = [Double](repeating: 0, count: AdaptiveFilterbank.bandCount)

    /// Set by `AudioState` to read live milli-dB from the per-ear
    /// processors. nil until wired — the loop then publishes idle.
    var gainMilliDBProvider: ((EQBandLookup.Ear, Int) -> Int64)?

    private var displayTimer: Timer?
    private var subscriberCount = 0
    private var screensAwake = true
    private let refreshHz: Double = 15

    private var sleepToken: NSObjectProtocol?
    private var wakeToken: NSObjectProtocol?

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        sleepToken = nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreensSlept() }
        }
        wakeToken = nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreensWoke() }
        }
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        if let sleepToken { nc.removeObserver(sleepToken) }
        if let wakeToken { nc.removeObserver(wakeToken) }
    }

    func gains(for ear: EQBandLookup.Ear) -> [Double] {
        ear == .left ? leftGainsDB : rightGainsDB
    }

    // MARK: - Subscriber lifecycle (mirrors DynamicActivityMonitor)

    func subscribe() {
        subscriberCount += 1
        if subscriberCount == 1, displayTimer == nil, screensAwake {
            startLoop()
        }
    }

    func unsubscribe() {
        guard subscriberCount > 0 else { return }
        subscriberCount -= 1
        if subscriberCount == 0 {
            displayTimer?.invalidate()
            displayTimer = nil
            if leftGainsDB != Self.idle { leftGainsDB = Self.idle }
            if rightGainsDB != Self.idle { rightGainsDB = Self.idle }
        }
    }

    private func handleScreensSlept() {
        screensAwake = false
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func handleScreensWoke() {
        screensAwake = true
        if subscriberCount > 0, displayTimer == nil {
            startLoop()
        }
    }

    private func startLoop() {
        let timer = Timer(timeInterval: 1.0 / refreshHz, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func tick() {
        guard let provider = gainMilliDBProvider else {
            if leftGainsDB != Self.idle { leftGainsDB = Self.idle }
            if rightGainsDB != Self.idle { rightGainsDB = Self.idle }
            return
        }
        var left = Self.idle
        var right = Self.idle
        for b in 0..<AdaptiveFilterbank.bandCount {
            left[b] = Double(provider(.left, b)) / 1000.0
            right[b] = Double(provider(.right, b)) / 1000.0
        }
        if left != leftGainsDB { leftGainsDB = left }
        if right != rightGainsDB { rightGainsDB = right }
    }
}
