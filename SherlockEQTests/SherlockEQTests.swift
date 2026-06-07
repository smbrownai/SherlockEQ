//
//  SherlockEQTests.swift
//  SherlockEQTests
//
//  Module smoke check — the per-area test suites live in the sibling
//  files (BiquadCoefficientsTests.swift, BiquadResponseTests.swift,
//  SafeListeningTrackerTests.swift, LogFreqAxisTests.swift). This file
//  exists only so the test target has an obvious entry point.
//

import Testing
@testable import SherlockEQ

struct SherlockEQModuleTests {

    @Test func canImportInternals() {
        // Smoke — if @testable import compiles and we can reach internal
        // types, every other suite can too.
        let band = EQBand(
            frequencyHz: 1000,
            gaindB: 0,
            bandwidth: 1.0,
            filterType: .parametric,
            enabled: true
        )
        #expect(band.frequencyHz == 1000)
    }
}
