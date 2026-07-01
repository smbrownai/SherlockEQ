//
//  AutoEQRemoteParserTests.swift
//  SherlockEQTests
//
//  ParametricEQ.txt files parsed here come from a public, technically
//  attacker-modifiable GitHub source. This covers the preamp gain clamp —
//  the one field that reaches the render thread as a direct sample
//  multiplier with no other bound in between.
//

import Testing
import Foundation
@testable import SherlockEQ

struct AutoEQRemoteParserTests {

    private static let entry = AutoEQIndexEntry(
        name: "Test Headphone", path: "test/over-ear/Test Headphone",
        source: "test", type: "over-ear"
    )

    @Test func extremePreampIsClampedToGainCeiling() throws {
        let text = """
        Preamp: 200 dB
        Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.0
        """
        let parsed = try #require(AutoEQRemoteParser.parse(text, entry: Self.entry))
        #expect(parsed.preampGain == BiquadCoefficients.gainClampDB)
    }

    @Test func negativeExtremePreampIsClampedToGainFloor() throws {
        let text = """
        Preamp: -200 dB
        Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.0
        """
        let parsed = try #require(AutoEQRemoteParser.parse(text, entry: Self.entry))
        #expect(parsed.preampGain == -BiquadCoefficients.gainClampDB)
    }

    @Test func nonFinitePreampIsTreatedAsMissing() throws {
        let text = """
        Preamp: nan dB
        Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.0
        """
        let parsed = try #require(AutoEQRemoteParser.parse(text, entry: Self.entry))
        #expect(parsed.preampGain == 0)
    }

    @Test func normalPreampIsUnaffectedByClamp() throws {
        let text = """
        Preamp: -6.5 dB
        Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.0
        """
        let parsed = try #require(AutoEQRemoteParser.parse(text, entry: Self.entry))
        #expect(parsed.preampGain == -6.5)
    }
}
