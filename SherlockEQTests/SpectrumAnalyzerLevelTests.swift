//
//  SpectrumAnalyzerLevelTests.swift
//  SherlockEQTests
//
//  The always-on level pass feeds the hearing-dose tracker, so it has to
//  answer "how hard is either ear being driven". It used to measure channel 0
//  alone: panning balance right, or playing one-sided material, left the dose
//  near zero while the right ear took full level — no alerts, and the
//  sustained-quiet reset could erase real accumulated exposure.
//
//  These pin the worst-ear rule so that can't come back.
//

import Testing
import Foundation
import AVFoundation
@testable import SherlockEQ

@MainActor
struct SpectrumAnalyzerLevelTests {

    /// Stereo buffer, constant amplitude per channel — a DC-ish block is fine
    /// here because the level pass is a mean-square, not a spectrum.
    private func stereoBuffer(left: Float, right: Float, frames: Int = 512) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = try #require(buffer.floatChannelData)
        for i in 0..<frames {
            channels[0][i] = left
            channels[1][i] = right
        }
        return buffer
    }

    /// One ingest per analyzer: `emitLevelIfDue` throttles to ~20 Hz, so a
    /// fresh instance is the reliable way to observe exactly one emission.
    private func levelReported(left: Float, right: Float) throws -> Float {
        let analyzer = SpectrumAnalyzer()
        let box = LevelBox()
        analyzer.onLevelUpdate = { dba in box.record(dba) }
        analyzer.ingest(try stereoBuffer(left: left, right: right))
        return try #require(box.value, "level pass did not emit")
    }

    /// The callback is `@Sendable` and fires synchronously on the calling
    /// thread here; a small class keeps the capture legal without actors.
    private final class LevelBox: @unchecked Sendable {
        private var stored: Float?
        private let lock = NSLock()
        func record(_ v: Float) { lock.lock(); stored = v; lock.unlock() }
        var value: Float? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    // MARK: - The reported bug

    /// Signal in the right channel only must read the same as the identical
    /// signal in the left. This is the exact failure: full-right balance used
    /// to report silence.
    @Test func rightEarOnlyReportsTheSameAsLeftEarOnly() throws {
        let leftOnly = try levelReported(left: 0.5, right: 0)
        let rightOnly = try levelReported(left: 0, right: 0.5)
        #expect(abs(leftOnly - rightOnly) < 0.01,
                "one-sided audio must report the same level in either ear")
    }

    /// A hard-panned signal must not be averaged down. (L+R)/2 would report
    /// ~3 dB quiet — the wrong direction for a safety meter.
    @Test func hardPanIsNotAveragedDown() throws {
        let panned = try levelReported(left: 0, right: 0.5)
        let centered = try levelReported(left: 0.5, right: 0.5)
        #expect(abs(panned - centered) < 0.01,
                "worst-ear means a panned signal reads like a centered one, not 3 dB quieter")
    }

    /// The louder ear wins regardless of which side it's on.
    @Test func louderEarDeterminesTheLevel() throws {
        let loudRight = try levelReported(left: 0.01, right: 0.5)
        let loudLeft = try levelReported(left: 0.5, right: 0.01)
        let bothLoud = try levelReported(left: 0.5, right: 0.5)
        #expect(abs(loudRight - bothLoud) < 0.01)
        #expect(abs(loudLeft - bothLoud) < 0.01)
    }

    /// Sanity: the meter still tracks level, so the max isn't pinning high.
    @Test func quieterAudioStillReadsQuieter() throws {
        let loud = try levelReported(left: 0.5, right: 0.5)
        let quiet = try levelReported(left: 0.05, right: 0.05)
        #expect(quiet < loud - 15, "a 20x amplitude drop is ~26 dB")
    }

    /// Silence must not be reported as a level — the quiet path is what
    /// `ExposureStatus` uses to decide "no audio", and a floor value here
    /// would make the app claim tracking during silence.
    @Test func silenceReportsFarBelowTheAudioFloor() throws {
        let silent = try levelReported(left: 0, right: 0)
        #expect(Double(silent) < ExposureStatus.audioFloorDBA,
                "silence must land under the audio floor")
    }

    // MARK: - The mono side channel is unaffected

    /// The pre-EQ side channel is already mono, so it has no ear to choose —
    /// this pins that the worst-ear change didn't disturb it.
    @Test func monoIngestStillReportsItsLevel() throws {
        let analyzer = SpectrumAnalyzer()
        let box = LevelBox()
        analyzer.onLevelUpdate = { dba in box.record(dba) }
        var samples = [Float](repeating: 0.5, count: 512)
        samples.withUnsafeBufferPointer { ptr in
            analyzer.ingest(monoSamples: ptr.baseAddress!, frameCount: 512)
        }
        let mono = try #require(box.value)
        let stereo = try levelReported(left: 0.5, right: 0.5)
        #expect(abs(mono - stereo) < 0.01,
                "mono at amplitude A should match stereo at amplitude A")
    }
}
