import Foundation
import Combine
import AppKit

/// Display-rate telemetry for the dynamic-EQ stage's activity meters
/// (Clarity panel + Expert "Dynamics" overlay). Polls the six
/// `AudioCounter` gain values exposed by the two `DynamicBandProcessor`s
/// (one per ear) at ~15 Hz and republishes them as signed dB deltas.
///
/// Deliberately a small, dedicated `ObservableObject` — meter views
/// observe it directly rather than going through `AudioState`, so the
/// 15 Hz refresh never rebroadcasts the whole `@EnvironmentObject` tree
/// (the 46 Hz spectrum-rebroadcast lesson — see project notes). The poll
/// loop is subscriber-refcounted: it only runs while a Clarity panel or
/// the Expert dynamics overlay is on screen, and it pauses when the
/// display sleeps — same gating discipline as `StereoMonitor`.
@MainActor
final class DynamicActivityMonitor: ObservableObject {

    /// Smoothed gain delta (dB) for one feature, both ears. Negative =
    /// cut in progress, positive = boost in progress, ~0 = idle.
    struct EarPair: Equatable {
        var left: Double = 0
        var right: Double = 0
    }

    @Published private(set) var gains: [DynamicFeatureKind: EarPair] = [:]

    /// Set by `AudioState` to read live signed milli-dB from the per-ear
    /// processors. nil until wired — the loop then publishes zeros.
    var deltaMilliDBProvider: ((DynamicFeatureKind, EQBandLookup.Ear) -> Int64)?

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

    /// Convenience read for views: current delta (dB) for one ear.
    func gain(_ kind: DynamicFeatureKind, _ ear: EQBandLookup.Ear) -> Double {
        let pair = gains[kind] ?? EarPair()
        return ear == .left ? pair.left : pair.right
    }

    // MARK: - Subscriber lifecycle (mirrors StereoMonitor)

    /// Call from a meter view's `.onAppear`. Spins up the poll loop on the
    /// first subscriber; idempotent thereafter.
    func subscribe() {
        subscriberCount += 1
        if subscriberCount == 1, displayTimer == nil, screensAwake {
            startLoop()
        }
    }

    /// Call from a meter view's `.onDisappear`. Tears the loop down when the
    /// last subscriber leaves and clears stale readings to idle.
    func unsubscribe() {
        guard subscriberCount > 0 else { return }
        subscriberCount -= 1
        if subscriberCount == 0 {
            displayTimer?.invalidate()
            displayTimer = nil
            if !gains.isEmpty { gains = [:] }
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
        // .common mode so the loop keeps firing during scroll / menu
        // tracking, matching the other display loops in the app.
        let timer = Timer(timeInterval: 1.0 / refreshHz, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func tick() {
        guard let provider = deltaMilliDBProvider else {
            if !gains.isEmpty { gains = [:] }
            return
        }
        var next: [DynamicFeatureKind: EarPair] = [:]
        for kind in DynamicFeatureKind.allCases {
            next[kind] = EarPair(
                left: Double(provider(kind, .left)) / 1000.0,
                right: Double(provider(kind, .right)) / 1000.0
            )
        }
        if next != gains { gains = next }
    }
}
