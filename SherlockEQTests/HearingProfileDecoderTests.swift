//
//  HearingProfileDecoderTests.swift
//  SherlockEQTests
//
//  Persistence-migration safety net. HearingProfile's custom Codable
//  init reads older JSON shapes (single shared `notch`, missing
//  `balance` / `eqMode` / `isBuiltIn` / `separateChannels` /
//  `separateNotch`) and coerces them into the current schema. Future
//  schema changes risk silently breaking user data on upgrade —
//  these fixtures catch the regression.
//

import Testing
import Foundation
@testable import SherlockEQ

struct HearingProfileDecoderTests {

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Legacy single-notch JSON

    @Test func legacySharedNotchPopulatesBothEars() throws {
        // Pre-per-ear-notch profiles stored one `notch` field. The
        // decoder must mirror it onto both leftNotch and rightNotch
        // so old data behaves exactly the same.
        let json = """
        {
          "id": "12345678-1234-5678-1234-567812345678",
          "name": "Legacy",
          "symbol": "person.fill",
          "leftEar": { "thresholds": [], "bands": [] },
          "rightEar": { "thresholds": [], "bands": [] },
          "notch": {
            "enabled": true,
            "frequencyHz": 8000,
            "depthdB": -12,
            "qWidth": "medium"
          },
          "globalTrimDB": 0,
          "safeListeningCeilingDB": 85,
          "compensationFactor": 0.5,
          "createdAt": "2025-01-01T00:00:00Z",
          "modifiedAt": "2025-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!

        let profile = try Self.decoder.decode(HearingProfile.self, from: json)
        #expect(profile.leftNotch.enabled)
        #expect(profile.leftNotch.frequencyHz == 8000)
        #expect(profile.rightNotch.enabled)
        #expect(profile.rightNotch.frequencyHz == 8000)
        #expect(profile.leftNotch == profile.rightNotch)
    }

    // MARK: - Defaults for missing newer fields

    @Test func missingBalanceDefaultsToCenter() throws {
        let json = Self.minimalLegacyJSON(omitting: "balance")
        let profile = try Self.decoder.decode(HearingProfile.self, from: json)
        #expect(profile.balance == 0)
    }

    @Test func missingEqModeDefaultsToExpert() throws {
        // Legacy profiles get .expert so users who scattered bands
        // across the old multi-tab UI still see everything on first
        // load. New profiles default to .advanced (Graphic) via the
        // designated init.
        let json = Self.minimalLegacyJSON(omitting: "eqMode")
        let profile = try Self.decoder.decode(HearingProfile.self, from: json)
        #expect(profile.eqMode == EQMode.expert)
    }

    @Test func retiredModesDecodeToGraphic() throws {
        // "simple" and "speech" were removed in the phase-3 surface
        // consolidation; profiles that stored them land on Graphic. Their
        // off-grid bands stay in storage and surface via the "Other
        // filters" row — nothing active becomes invisible.
        for retired in ["simple", "speech"] {
            let data = "\"\(retired)\"".data(using: .utf8)!
            let mode = try JSONDecoder().decode(EQMode.self, from: data)
            #expect(mode == .advanced)
        }
    }

    @Test func survivingModesRoundTripTheirRawValues() throws {
        // Persisted raw values are frozen ("advanced" / "expert") even
        // though display names changed to Graphic / Parametric — old
        // exports must keep importing, and re-saves must not churn JSON.
        for (raw, mode) in [("advanced", EQMode.advanced), ("expert", EQMode.expert)] {
            let decoded = try JSONDecoder().decode(EQMode.self, from: "\"\(raw)\"".data(using: .utf8)!)
            #expect(decoded == mode)
            let encoded = String(data: try JSONEncoder().encode(mode), encoding: .utf8)
            #expect(encoded == "\"\(raw)\"")
        }
    }

    @Test func missingCorrectionModeDecodesToSteady() throws {
        // Every profile written before Phase 4 must keep today's behavior:
        // the static NAL-R layer, never Adaptive.
        let json = Self.minimalLegacyJSON(omitting: "correctionMode")
        let profile = try Self.decoder.decode(HearingProfile.self, from: json)
        #expect(profile.correctionMode == .steady)
    }

    @Test func correctionModeRoundTripsAndTolerates() throws {
        for (raw, mode) in [("steady", CorrectionMode.steady), ("adaptive", .adaptive)] {
            let decoded = try JSONDecoder().decode(CorrectionMode.self, from: "\"\(raw)\"".data(using: .utf8)!)
            #expect(decoded == mode)
        }
        // Unknown future strings land on the safe default.
        let unknown = try JSONDecoder().decode(CorrectionMode.self, from: "\"turbo\"".data(using: .utf8)!)
        #expect(unknown == .steady)
    }

    @Test func missingAutoEQDeviceFieldsDecodeToNil() throws {
        // Corrections attached before the device-mismatch feature carry no
        // recorded device — they must decode (nil) and produce no warning.
        let json = Self.minimalLegacyJSON(omitting: "autoEQDeviceUID")
        let profile = try Self.decoder.decode(HearingProfile.self, from: json)
        #expect(profile.autoEQDeviceUID == nil)
        #expect(profile.autoEQDeviceName == nil)
    }

    @Test func missingIsBuiltInDefaultsToFalse() throws {
        let json = Self.minimalLegacyJSON(omitting: "isBuiltIn")
        let profile = try Self.decoder.decode(HearingProfile.self, from: json)
        #expect(!profile.isBuiltIn)
    }

    @Test func missingSeparateChannelsDefaultsToFalse() throws {
        let json = Self.minimalLegacyJSON(omitting: "separateChannels")
        let profile = try Self.decoder.decode(HearingProfile.self, from: json)
        #expect(!profile.separateChannels)
    }

    @Test func missingSeparateNotchDefaultsToFalse() throws {
        let json = Self.minimalLegacyJSON(omitting: "separateNotch")
        let profile = try Self.decoder.decode(HearingProfile.self, from: json)
        #expect(!profile.separateNotch)
    }

    // MARK: - Modern JSON round-trip

    @Test func modernProfileRoundTripsThroughEncoder() throws {
        // A profile minted via the designated initializer must
        // encode and decode back to an audibly-equivalent profile.
        let original = HearingProfile.makeDefault(name: "Round-trip", isBuiltIn: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoded = try Self.decoder.decode(HearingProfile.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.balance == original.balance)
        #expect(decoded.eqMode == original.eqMode)
        #expect(decoded.separateChannels == original.separateChannels)
        #expect(decoded.isBuiltIn == original.isBuiltIn)
        #expect(decoded.leftEar.bands.audiblyEquivalent(to: original.leftEar.bands))
        #expect(decoded.rightEar.bands.audiblyEquivalent(to: original.rightEar.bands))
    }

    @Test func perEarNotchSurvivesRoundTrip() throws {
        // Modern profile WITH distinct per-ear notch values — encode
        // then decode should preserve the asymmetry, not collapse it.
        var original = HearingProfile.makeDefault()
        original.separateNotch = true
        original.leftNotch  = TinnitusNotch(enabled: true, frequencyHz: 7000, depthdB: -9, qWidth: .medium)
        original.rightNotch = TinnitusNotch(enabled: true, frequencyHz: 9000, depthdB: -6, qWidth: .narrow)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoded = try Self.decoder.decode(HearingProfile.self, from: data)

        #expect(decoded.separateNotch)
        #expect(decoded.leftNotch.frequencyHz == 7000)
        #expect(decoded.rightNotch.frequencyHz == 9000)
        #expect(decoded.leftNotch != decoded.rightNotch)
    }

    // MARK: - Fixture helpers

    /// A minimal modern-shape profile JSON missing one specified field.
    /// Lets each test target exactly one optional-field migration path.
    private static func minimalLegacyJSON(omitting key: String) -> Data {
        var fields: [String: String] = [
            "id":                     "\"22222222-2222-2222-2222-222222222222\"",
            "name":                   "\"Test\"",
            "symbol":                 "\"person.fill\"",
            "leftEar":                "{ \"thresholds\": [], \"bands\": [] }",
            "rightEar":               "{ \"thresholds\": [], \"bands\": [] }",
            "leftNotch":              "{ \"enabled\": false, \"frequencyHz\": 6000, \"depthdB\": -6, \"qWidth\": \"medium\" }",
            "rightNotch":             "{ \"enabled\": false, \"frequencyHz\": 6000, \"depthdB\": -6, \"qWidth\": \"medium\" }",
            "separateNotch":          "false",
            "globalTrimDB":           "0",
            "balance":                "0",
            "safeListeningCeilingDB": "85",
            "compensationFactor":     "0.5",
            "separateChannels":       "false",
            "eqMode":                 "\"simple\"",
            "isBuiltIn":              "false",
            "createdAt":              "\"2025-01-01T00:00:00Z\"",
            "modifiedAt":             "\"2025-01-01T00:00:00Z\"",
        ]
        fields.removeValue(forKey: key)
        let body = fields.map { "\"\($0.key)\": \($0.value)" }.joined(separator: ", ")
        return ("{ " + body + " }").data(using: .utf8)!
    }
}
