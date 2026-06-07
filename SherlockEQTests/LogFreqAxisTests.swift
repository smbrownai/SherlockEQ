//
//  LogFreqAxisTests.swift
//  SherlockEQTests
//
//  Round-trip + clamping invariants for the shared log-frequency
//  helper used by every canvas/graph that maps Hz to pixels.
//

import Testing
import Foundation
import CoreGraphics
@testable import SherlockEQ

struct LogFreqAxisTests {

    private static let audibleAxis = LogFreqAxis(minHz: 20, maxHz: 20_000)

    // MARK: - Endpoints

    @Test func endpointsAreZeroAndOne() {
        let a = Self.audibleAxis
        #expect(abs(a.frac(forHz: 20) - 0.0) < 1e-12)
        #expect(abs(a.frac(forHz: 20_000) - 1.0) < 1e-12)
    }

    @Test func midpointHzIsGeometricMean() {
        // Log space: frac 0.5 ↔ sqrt(min*max) = sqrt(20 * 20_000) = 632.45…
        let a = Self.audibleAxis
        let midHz = a.hz(forFrac: 0.5)
        let expected = (20.0 * 20_000.0).squareRoot()
        #expect(abs(midHz - expected) / expected < 1e-9)
    }

    // MARK: - Round-trip

    @Test(arguments: [50.0, 100.0, 250.0, 1000.0, 4000.0, 12_000.0, 19_000.0])
    func hzToFracToHzIsIdempotent(hz: Double) {
        let a = Self.audibleAxis
        let roundTripped = a.hz(forFrac: a.frac(forHz: hz))
        #expect(abs(roundTripped - hz) / hz < 1e-12, "round-trip drift at \(hz) Hz")
    }

    @Test(arguments: [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0])
    func fracToHzToFracIsIdempotent(frac: Double) {
        let a = Self.audibleAxis
        let roundTripped = a.frac(forHz: a.hz(forFrac: frac))
        #expect(abs(roundTripped - frac) < 1e-12, "round-trip drift at frac \(frac)")
    }

    // MARK: - Pixel mapping

    @Test func xForHzZeroForMinAndWidthForMax() {
        let a = Self.audibleAxis
        #expect(a.x(forHz: 20, width: 800) == 0)
        // Floating-point round-off — expect very close to 800, not exact.
        #expect(abs(a.x(forHz: 20_000, width: 800) - 800) < 1e-9)
    }

    @Test(arguments: [0.0, 100.0, 400.0, 800.0])
    func xToHzToXIsIdempotent(x: CGFloat) {
        let a = Self.audibleAxis
        let hz = a.hz(forX: x, width: 800)
        let roundTripped = a.x(forHz: hz, width: 800)
        #expect(abs(roundTripped - x) < 1e-9, "round-trip drift at x=\(x)")
    }

    @Test func xWidthZeroReturnsMinHz() {
        // Defensive: width=0 must not produce NaN.
        let a = Self.audibleAxis
        let hz = a.hz(forX: 100, width: 0)
        #expect(hz == 20)
    }

    // MARK: - Clamping

    @Test func fracClampedRespectsBounds() {
        // Below-min frequency yields a negative fraction unclamped, 0
        // clamped. Above-max yields >1 unclamped, 1 clamped.
        let a = Self.audibleAxis
        let underUnclamped = a.frac(forHz: 10)
        let underClamped   = a.frac(forHz: 10, clamped: true)
        #expect(underUnclamped < 0)
        #expect(underClamped == 0)

        let overUnclamped = a.frac(forHz: 40_000)
        let overClamped   = a.frac(forHz: 40_000, clamped: true)
        #expect(overUnclamped > 1)
        #expect(overClamped == 1)
    }

    @Test func xForHzClampsToCanvasEdges() {
        // x(forHz:width:) clamps Hz to the axis endpoints before
        // mapping, so out-of-range Hz lands on an edge.
        let a = Self.audibleAxis
        #expect(a.x(forHz: 10, width: 800) == 0)
        #expect(abs(a.x(forHz: 50_000, width: 800) - 800) < 1e-9)
    }

    @Test func hzForXClampsToCanvasEdges() {
        // x outside [0, width] clamps too. The under-clamp goes through
        // pow(10, log10(20)) which round-trips with a few-ULP drift, so
        // compare with a tolerance rather than `==`.
        let a = Self.audibleAxis
        #expect(abs(a.hz(forX: -100, width: 800) - 20) < 1e-9)
        #expect(abs(a.hz(forX: 1000, width: 800) - 20_000) < 1e-9)
    }
}
