import Foundation
import AVFoundation
import os

/// Single-producer / single-consumer ring buffer for one channel of Float32 audio.
/// Producer: Core Audio IOProc. Consumer: AVAudioSourceNode render block.
///
/// Sync: a single `OSAllocatedUnfairLock` guards the read/write indices.
/// Data regions are disjoint by construction, so the lock is held only for index
/// updates — microsecond contention window. This is fine for Session-stage work;
/// a lock-free atomics swap is a drop-in later.
final class TapRingBuffer {

    let capacityFrames: Int

    private let storage: UnsafeMutableBufferPointer<Float>
    private let indices = OSAllocatedUnfairLock<Indices>(initialState: Indices(read: 0, write: 0, dropped: 0))

    private struct Indices { var read: Int; var write: Int; var dropped: Int }

    /// Total frames dropped to overflow since creation (for diagnostics).
    /// Non-zero indicates the consumer stalled and the oldest audio was
    /// discarded to keep latency bounded. Lock-guarded; safe to read off-thread.
    var droppedFrameCount: Int { indices.withLock { $0.dropped } }

    init(capacityFrames: Int) {
        let cap = Self.nextPowerOfTwo(max(64, capacityFrames))
        self.capacityFrames = cap
        let raw = UnsafeMutableBufferPointer<Float>.allocate(capacity: cap)
        raw.initialize(repeating: 0)
        self.storage = raw
    }

    deinit { storage.deallocate() }

    // MARK: - Producer

    /// Reserve room for `frameCount` frames, dropping the *oldest* frames if the
    /// ring would overflow. Returns the write index to start at and the number
    /// of frames to write (clamped to capacity).
    ///
    /// Overflow policy is drop-oldest (advance `read`), not drop-newest: when
    /// the consumer (render block) stalls and the ring fills, dropping the
    /// newest frames pins latency at maximum and produces *steady-state*
    /// dropouts that never recover while production keeps up with consumption.
    /// Discarding the oldest frames instead keeps the freshest audio, bounds
    /// latency, and self-heals after a single glitch. Advancing `read` from the
    /// producer is normally the consumer's job, but every index mutation is
    /// lock-guarded, so the only consequence is at most one buffer of stale
    /// samples on the consumer side — a one-time glitch, not a persistent one.
    private func reserveWrite(_ frameCount: Int) -> (w: Int, toWrite: Int) {
        indices.withLock { state in
            let toWrite = min(frameCount, capacityFrames)
            let free = capacityFrames - (state.write &- state.read)
            if toWrite > free {
                let overflow = toWrite - free
                state.read = state.read &+ overflow
                state.dropped = state.dropped &+ overflow
            }
            return (state.write, toWrite)
        }
    }

    /// Writes `frameCount` mono samples from `src` into the ring. On overflow
    /// the oldest buffered frames are dropped (see `reserveWrite`).
    func write(from src: UnsafePointer<Float>, frameCount: Int) {
        if frameCount <= 0 { return }
        let (w, toWrite) = reserveWrite(frameCount)
        if toWrite <= 0 { return }

        let mask = capacityFrames - 1
        let storagePtr = storage.baseAddress!

        for i in 0..<toWrite {
            storagePtr[(w &+ i) & mask] = src[i]
        }

        indices.withLock { state in state.write = state.write &+ toWrite }
    }

    /// Producer convenience: pull one channel from an interleaved stereo source.
    /// `interleavedSrc` points at L0,R0,L1,R1,…; `channelIndex` is 0 (L) or 1 (R).
    func writeChannel(
        from interleavedSrc: UnsafePointer<Float>,
        frameCount: Int,
        channelIndex: Int,
        channelCount: Int
    ) {
        if frameCount <= 0 { return }
        let (w, toWrite) = reserveWrite(frameCount)
        if toWrite <= 0 { return }

        let mask = capacityFrames - 1
        let storagePtr = storage.baseAddress!

        for i in 0..<toWrite {
            storagePtr[(w &+ i) & mask] = interleavedSrc[i * channelCount + channelIndex]
        }

        indices.withLock { state in state.write = state.write &+ toWrite }
    }

    // MARK: - Consumer

    /// Reads up to `frameCount` mono samples into `dst`. Returns frames actually read.
    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        let (r, available) = indices.withLock { state -> (Int, Int) in
            (state.read, state.write &- state.read)
        }
        let toRead = min(frameCount, available)
        if toRead <= 0 { return 0 }

        let mask = capacityFrames - 1
        let storagePtr = storage.baseAddress!

        for i in 0..<toRead {
            dst[i] = storagePtr[(r &+ i) & mask]
        }

        indices.withLock { state in state.read = state.read &+ toRead }
        return toRead
    }

    // MARK: - Helpers

    private static func nextPowerOfTwo(_ n: Int) -> Int {
        var v = n - 1
        v |= v >> 1; v |= v >> 2; v |= v >> 4; v |= v >> 8; v |= v >> 16; v |= v >> 32
        return v + 1
    }
}
