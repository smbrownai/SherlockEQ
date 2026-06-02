import Foundation
import AVFoundation
import os

/// Single-producer / single-consumer ring buffer for Float32 audio samples.
/// Producer: Core Audio IOProc. Consumer: AVAudioSourceNode render block.
///
/// Synchronisation: a single `OSAllocatedUnfairLock` guards the read/write indices.
/// The data regions themselves are disjoint by construction (producer writes only
/// to the head segment, consumer reads only from the tail segment), so we hold the
/// lock for index updates only — microsecond-scale contention.
///
/// This is sufficient for Session 1. A lock-free swap (swift-atomics or Swift 6
/// `Synchronization.Atomic`) is a drop-in upgrade later.
final class TapRingBuffer {

    let channelCount: Int
    let capacityFrames: Int

    private let storage: UnsafeMutableBufferPointer<Float>
    private let indices = OSAllocatedUnfairLock<Indices>(initialState: Indices(read: 0, write: 0))

    private struct Indices { var read: Int; var write: Int }

    init(channelCount: Int, capacityFrames: Int) {
        self.channelCount = max(1, channelCount)
        let cap = Self.nextPowerOfTwo(max(64, capacityFrames))
        self.capacityFrames = cap
        let count = cap * self.channelCount
        let raw = UnsafeMutableBufferPointer<Float>.allocate(capacity: count)
        raw.initialize(repeating: 0)
        self.storage = raw
    }

    deinit { storage.deallocate() }

    // MARK: - Producer (IOProc)

    func write(from abl: UnsafeMutableAudioBufferListPointer) {
        guard let first = abl.first else { return }
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / max(1, Int(first.mNumberChannels))
        if frames <= 0 { return }

        let (w, available) = indices.withLock { state -> (Int, Int) in
            (state.write, capacityFrames - (state.write &- state.read))
        }
        let toWrite = min(frames, available)
        if toWrite <= 0 { return }

        let mask = capacityFrames - 1
        let storagePtr = storage.baseAddress!
        let channels = channelCount

        if abl.count == 1 && first.mNumberChannels == UInt32(channels), let firstPtr = first.mData {
            // Interleaved source.
            let src = firstPtr.assumingMemoryBound(to: Float.self)
            for i in 0..<toWrite {
                let dstOffset = ((w &+ i) & mask) * channels
                let srcOffset = i * channels
                for ch in 0..<channels {
                    storagePtr[dstOffset + ch] = src[srcOffset + ch]
                }
            }
        } else {
            // Non-interleaved source: one mBuffer per channel.
            for i in 0..<toWrite {
                let dstOffset = ((w &+ i) & mask) * channels
                for ch in 0..<min(channels, abl.count) {
                    guard let chPtr = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    storagePtr[dstOffset + ch] = chPtr[i]
                }
            }
        }

        indices.withLock { state in state.write = state.write &+ toWrite }
    }

    // MARK: - Consumer (AVAudioSourceNode render block)

    @discardableResult
    func read(into abl: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) -> Int {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)

        let (r, available) = indices.withLock { state -> (Int, Int) in
            (state.read, state.write &- state.read)
        }
        let toRead = min(frameCount, available)
        if toRead <= 0 { return 0 }

        let mask = capacityFrames - 1
        let storagePtr = storage.baseAddress!
        let channels = channelCount

        if buffers.count == 1 && buffers[0].mNumberChannels == UInt32(channels) {
            guard let dst = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return 0 }
            for i in 0..<toRead {
                let srcOffset = ((r &+ i) & mask) * channels
                let dstOffset = i * channels
                for ch in 0..<channels {
                    dst[dstOffset + ch] = storagePtr[srcOffset + ch]
                }
            }
        } else {
            for i in 0..<toRead {
                let srcOffset = ((r &+ i) & mask) * channels
                for ch in 0..<min(channels, buffers.count) {
                    guard let chPtr = buffers[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    chPtr[i] = storagePtr[srcOffset + ch]
                }
            }
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
