import Foundation
import Combine

/// Master gain + AUPeakLimiter parameters — the four numeric knobs
/// the user can dial in from Settings to shape the post-EQ output.
/// Each value persists to UserDefaults via `didSet` so settings
/// survive relaunch; AudioState sinks each `$value` publisher and
/// pushes the result into the engine reactively. EngineParameters
/// itself knows nothing about the engine, which keeps it testable
/// in isolation.
///
/// Re-applied to the engine on every graph rebuild so a
/// teardown/reattach cycle (output device switch, sleep/wake) doesn't
/// drop the user's settings.
@MainActor
final class EngineParameters: ObservableObject {

    /// Master output gain, post-limiter, in dB. Clamped to +12 dB in
    /// the engine's gain stage so the limiter still has headroom; -60
    /// is effectively inaudible.
    @Published var masterGainDB: Double = EngineParameters.loadDouble(
        key: EngineParameters.masterGainKey,
        default: 0
    ) {
        didSet { UserDefaults.standard.set(masterGainDB, forKey: Self.masterGainKey) }
    }

    /// AUPeakLimiter attack time in milliseconds. Snappier for
    /// transient material, longer for sustained mixes.
    @Published var limiterAttackMs: Double = EngineParameters.loadDouble(
        key: EngineParameters.limiterAttackKey,
        default: 12.0
    ) {
        didSet { UserDefaults.standard.set(limiterAttackMs, forKey: Self.limiterAttackKey) }
    }

    /// AUPeakLimiter decay (release) time in milliseconds.
    @Published var limiterDecayMs: Double = EngineParameters.loadDouble(
        key: EngineParameters.limiterDecayKey,
        default: 24.0
    ) {
        didSet { UserDefaults.standard.set(limiterDecayMs, forKey: Self.limiterDecayKey) }
    }

    /// dB of gain applied *into* the limiter — pushing harder into the
    /// curve. Distinct from masterGainDB which sits post-limiter.
    @Published var limiterPreGainDB: Double = EngineParameters.loadDouble(
        key: EngineParameters.limiterPreGainKey,
        default: 0
    ) {
        didSet { UserDefaults.standard.set(limiterPreGainDB, forKey: Self.limiterPreGainKey) }
    }

    private static let masterGainKey = "auditumeq.masterGainDB"
    private static let limiterAttackKey = "auditumeq.limiterAttackMs"
    private static let limiterDecayKey = "auditumeq.limiterDecayMs"
    private static let limiterPreGainKey = "auditumeq.limiterPreGainDB"

    private static func loadDouble(key: String, default defaultValue: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? defaultValue
    }
}
