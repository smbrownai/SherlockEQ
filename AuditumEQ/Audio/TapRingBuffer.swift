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
    private let indices = OSAllocatedUnfairLock<Indices>(initialState: Indices(read: 0, write: 0))

    private struct Indices { var read: Int; var write: Int }

    init(capacityFrames: Int) {
        let cap = Self.nextPowerOfTwo(max(64, capacityFrames))
        self.capacityFrames = cap
        let raw = UnsafeMutableBufferPointer<Float>.allocate(capacity: cap)
        raw.initialize(repeating: 0)
        self.storage = raw
    }

    deinit { storage.deallocate() }

    // MARK: - Producer

    /// Writes `frameCount` mono samples from `src` into the ring.
    /// Frames beyond available capacity are dropped (callers should over-provision).
    func write(from src: UnsafePointer<Float>, frameCount: Int) {
        let (w, available) = indices.withLock { state -> (Int, Int) in
            (state.write, capacityFrames - (state.write &- state.read))
        }
        let toWrite = min(frameCount, available)
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
        let (w, available) = indices.withLock { state -> (Int, Int) in
            (state.write, capacityFrames - (state.write &- state.read))
        }
        let toWrite = min(frameCount, available)
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
