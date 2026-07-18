//
//  SpectrumAnalyzerCallbackTests.swift
//  SherlockEQTests
//
//  Regression guard for the 0.9.1 crash: repeatedly reading + calling the
//  level callback must not grow the stored closure.
//
//  A bare closure stored as the generic `State` of an OSAllocatedUnfairLock is
//  held at the maximally abstract calling convention, so every access
//  reabstracts it — and `withLock` yields `inout`, so the reabstracted copy is
//  written back. The stored closure gained one thunk layer per access; at the
//  20 Hz emit rate that reached ~6,600 nested layers in ~11 minutes and blew
//  the audio thread's 544 KB stack (EXC_BAD_ACCESS, "excessive recursion").
//  The fix boxes the closure in a concrete struct. This test fails loudly if
//  anyone reintroduces a bare-closure generic slot.
//

import Testing
import Foundation
@testable import SherlockEQ

@MainActor
struct SpectrumAnalyzerCallbackTests {

    /// Call depth observed from inside the handler must be identical on the
    /// first call and after thousands more. With the old bare-closure storage
    /// this grew by two frames per call and would eventually overflow.
    @Test func repeatedCallsDoNotGrowTheStoredCallback() {
        let analyzer = SpectrumAnalyzer()
        let probe = DepthProbe()
        analyzer.onLevelUpdate = { _ in
            probe.depth = Thread.callStackSymbols.count
        }

        analyzer.onLevelUpdate?(-40)
        let firstDepth = probe.depth
        #expect(firstDepth > 0, "handler should have run")

        for _ in 0..<5_000 {
            analyzer.onLevelUpdate?(-40)
        }

        // Allow a tiny tolerance for incidental frame differences; the bug
        // produced +10,000 frames over this many iterations, so any real
        // regression is unmissable.
        let growth = probe.depth - firstDepth
        #expect(growth <= 2,
                "stored callback grew by \(growth) frames over 5,000 accesses — the closure is being reabstracted and written back")
    }

    /// The callback still delivers the value it's given (the boxing must not
    /// change behavior), and installing a new one replaces rather than nests.
    @Test func callbackDeliversValueAndReplacesCleanly() {
        let analyzer = SpectrumAnalyzer()
        let first = ValueProbe()
        let second = ValueProbe()

        analyzer.onLevelUpdate = { first.record($0) }
        analyzer.onLevelUpdate?(-12.5)
        #expect(first.values == [-12.5])

        analyzer.onLevelUpdate = { second.record($0) }
        analyzer.onLevelUpdate?(-30)
        #expect(second.values == [-30])
        // The replaced handler must NOT still be chained in.
        #expect(first.values == [-12.5], "old handler should be replaced, not wrapped")

        analyzer.onLevelUpdate = nil
        analyzer.onLevelUpdate?(-1)
        #expect(second.values == [-30], "clearing should stop delivery")
    }

    // MARK: - Probes

    private final class DepthProbe: @unchecked Sendable {
        var depth = 0
    }

    private final class ValueProbe: @unchecked Sendable {
        private(set) var values: [Float] = []
        func record(_ v: Float) { values.append(v) }
    }
}
