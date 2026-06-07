import Foundation
import os

/// Lock-guarded Int64 counter for cross-thread diagnostic counters
/// (realtime IOProc / render block ⇆ MainActor UI). Increments are racy-tolerant
/// in spirit but locked here for correctness — microsecond contention is fine
/// for a counter sampled at ~10 Hz from the UI.
final class AudioCounter: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock<Int64>(initialState: 0)

    func add(_ n: Int) { value.withLock { $0 &+= Int64(n) } }
    func read() -> Int64 { value.withLock { $0 } }
    func reset() { value.withLock { $0 = 0 } }
    /// Set the value directly (used as a rolling peak from realtime threads).
    func set(_ v: Int64) { value.withLock { $0 = v } }
}
