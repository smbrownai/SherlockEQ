//
//  AutoEQParserTests.swift
//  SherlockEQTests
//
//  Real-world AutoEQ ParametricEQ.txt files are the source of every
//  headphone correction users load. Parse failures here mean a user's
//  headphone profile silently does nothing.
//

import Testing
import Foundation
@testable import SherlockEQ

struct AutoEQParserTests {

    // MARK: - Canonical AutoEQ format

    @Test func parsesPreampAndAllFilterTypes() throws {
        let text = """
        Preamp: -6.0 dB
        Filter 1: ON PK Fc 100 Hz Gain -3.5 dB Q 1.000
        Filter 2: ON LSC Fc 105 Hz Gain 1.5 dB Q 0.71
        Filter 3: ON HSC Fc 10000 Hz Gain -2.0 dB Q 0.71
        """
        let parsed = try #require(AutoEQParser.parse(text))
        #expect(parsed.preampDB == -6.0)
        #expect(parsed.bands.count == 3)

        #expect(parsed.bands[0].filterType == .parametric)
        #expect(parsed.bands[0].frequencyHz == 100)
        #expect(parsed.bands[0].gaindB == -3.5)
        #expect(parsed.bands[0].bandwidth == 1.0)

        #expect(parsed.bands[1].filterType == .lowShelf)
        #expect(parsed.bands[1].frequencyHz == 105)

        #expect(parsed.bands[2].filterType == .highShelf)
        #expect(parsed.bands[2].frequencyHz == 10_000)
    }

    @Test func filterTypeAliasesAreAccepted() throws {
        // Different producers use varying type tokens — PEQ/PK,
        // LSC/LS/LowShelf, HSC/HS/HighShelf.
        let text = """
        Filter 1: ON PEQ Fc 1000 Hz Gain 0 dB Q 1.0
        Filter 2: ON LS Fc 60 Hz Gain 2 dB Q 0.7
        Filter 3: ON HighShelf Fc 8000 Hz Gain -1 dB Q 0.7
        """
        let parsed = try #require(AutoEQParser.parse(text))
        #expect(parsed.bands.count == 3)
        #expect(parsed.bands[0].filterType == .parametric)
        #expect(parsed.bands[1].filterType == .lowShelf)
        #expect(parsed.bands[2].filterType == .highShelf)
    }

    // MARK: - OFF / NO filters

    @Test func disabledFilterIsParsedButNotEnabled() throws {
        let text = """
        Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.0
        Filter 2: OFF PK Fc 4000 Hz Gain 6 dB Q 1.0
        """
        let parsed = try #require(AutoEQParser.parse(text))
        #expect(parsed.bands.count == 2)
        #expect(parsed.bands[0].enabled)
        #expect(!parsed.bands[1].enabled)
    }

    @Test func noFilterTypeIsSkipped() throws {
        // "NO" / "OFF" / "NONE" as a type token mean "no filter in
        // this slot" — different from a disabled PK band, and the
        // parser drops them entirely so they don't waste a slot.
        let text = """
        Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.0
        Filter 2: ON NO Fc 0 Hz Gain 0 dB Q 0
        Filter 3: ON PK Fc 4000 Hz Gain -3 dB Q 1.0
        """
        let parsed = try #require(AutoEQParser.parse(text))
        #expect(parsed.bands.count == 2)
        #expect(parsed.bands.map(\.frequencyHz) == [1000, 4000])
    }

    // MARK: - Format tolerance

    @Test func blankLinesAndCommentsAreIgnored() throws {
        let text = """
        # AutoEQ-generated, do not edit
        Preamp: -3.0 dB

        Filter 1: ON PK Fc 1000 Hz Gain 2 dB Q 1.0

        # next band
        Filter 2: ON PK Fc 4000 Hz Gain -2 dB Q 1.0
        """
        let parsed = try #require(AutoEQParser.parse(text))
        #expect(parsed.preampDB == -3.0)
        #expect(parsed.bands.count == 2)
    }

    @Test func decimalPrecisionVariationsParse() throws {
        // Different producers emit different decimal precision —
        // "100 Hz", "100.0 Hz", "1000.500 Hz" all need to round-trip.
        let text = """
        Filter 1: ON PK Fc 100 Hz Gain -3 dB Q 1
        Filter 2: ON PK Fc 1000.5 Hz Gain -2.75 dB Q 0.707
        Filter 3: ON PK Fc 10000.00 Hz Gain 1.25 dB Q 1.500
        """
        let parsed = try #require(AutoEQParser.parse(text))
        #expect(parsed.bands.count == 3)
        #expect(parsed.bands[0].frequencyHz == 100)
        #expect(parsed.bands[1].frequencyHz == 1000.5)
        #expect(parsed.bands[1].gaindB == -2.75)
        #expect(parsed.bands[2].bandwidth == 1.5)
    }

    @Test func preampDefaultsToZeroWhenMissing() throws {
        let text = """
        Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.0
        """
        let parsed = try #require(AutoEQParser.parse(text))
        #expect(parsed.preampDB == 0)
    }

    @Test func extremePreampIsClampedToGainCeiling() throws {
        // A corrupted or malicious ParametricEQ.txt shouldn't be able to
        // drive raw samples by orders of magnitude — clamp at the same
        // ceiling the per-band gain uses.
        let text = """
        Preamp: 200 dB
        Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.0
        """
        let parsed = try #require(AutoEQParser.parse(text))
        #expect(parsed.preampDB == BiquadCoefficients.gainClampDB)
    }

    @Test func negativeExtremePreampIsClampedToGainFloor() throws {
        let text = """
        Preamp: -200 dB
        Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.0
        """
        let parsed = try #require(AutoEQParser.parse(text))
        #expect(parsed.preampDB == -BiquadCoefficients.gainClampDB)
    }

    @Test func nonFinitePreampFallsBackToZero() throws {
        // Double("nan") parses successfully to NaN — must not reach the
        // render path unfiltered; falls back to the same 0 dB default as a
        // missing Preamp line.
        let text = """
        Preamp: nan dB
        Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.0
        """
        let parsed = try #require(AutoEQParser.parse(text))
        #expect(parsed.preampDB == 0)
    }

    // MARK: - Malformed input

    @Test func emptyInputReturnsNil() {
        #expect(AutoEQParser.parse("") == nil)
    }

    @Test func onlyCommentsReturnsNil() {
        #expect(AutoEQParser.parse("# nothing here\n# nope\n") == nil)
    }

    @Test func onlyPreampReturnsNil() {
        // No bands → nothing to apply, parser bails.
        #expect(AutoEQParser.parse("Preamp: -3.0 dB\n") == nil)
    }

    /// "nan"/"inf" parse as valid Doubles, so without an explicit guard a
    /// poisoned Fc or Gain sails through to the biquad math (audit SEC-03 —
    /// Preamp and Q were already guarded). The row must drop; its healthy
    /// neighbours must survive.
    @Test func nonFiniteFcOrGainRowIsSkipped() throws {
        let text = """
        Filter 1: ON PK Fc nan Hz Gain 3 dB Q 1.0
        Filter 2: ON PK Fc 1000 Hz Gain inf dB Q 1.0
        Filter 3: ON PK Fc 4000 Hz Gain -2 dB Q 1.0
        """
        let parsed = try #require(AutoEQParser.parse(text))
        #expect(parsed.bands.count == 1)
        #expect(parsed.bands[0].frequencyHz == 4000)
    }

    @Test func malformedFilterLineIsSkipped() throws {
        // Bad lines are dropped, good lines survive — robust to one
        // typo in a long file.
        let text = """
        Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.0
        Filter 2: WAT IS THIS
        Filter 3: ON PK Fc 4000 Hz Gain -2 dB Q 1.0
        """
        let parsed = try #require(AutoEQParser.parse(text))
        #expect(parsed.bands.count == 2)
        #expect(parsed.bands.map(\.frequencyHz) == [1000, 4000])
    }

    @Test func unknownFilterTypeIsSkipped() throws {
        // E.g. "BP" (band-pass) — AutoEQ doesn't emit these, and we
        // don't translate them, so drop rather than guess.
        let text = """
        Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.0
        Filter 2: ON BP Fc 4000 Hz Gain -2 dB Q 1.0
        """
        let parsed = try #require(AutoEQParser.parse(text))
        #expect(parsed.bands.count == 1)
        #expect(parsed.bands[0].frequencyHz == 1000)
    }

    @Test func extremeQIsClamped() throws {
        // A hand-edited or corrupted file shouldn't be able to push Q outside
        // the same [0.1, 16.0] range AutoEQRemoteParser already enforces.
        let text = """
        Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1e10
        Filter 2: ON PK Fc 4000 Hz Gain -3 dB Q -5
        """
        let parsed = try #require(AutoEQParser.parse(text))
        #expect(parsed.bands[0].bandwidth == 16.0)
        #expect(parsed.bands[1].bandwidth == 0.1)
    }

    @Test func missingFcReturnsNil() throws {
        // A filter line missing the Fc label fails parse for that
        // line; the line is dropped from the result.
        let text = """
        Filter 1: ON PK Gain 3 dB Q 1.0
        Filter 2: ON PK Fc 4000 Hz Gain -2 dB Q 1.0
        """
        let parsed = try #require(AutoEQParser.parse(text))
        #expect(parsed.bands.count == 1)
        #expect(parsed.bands[0].frequencyHz == 4000)
    }
}
