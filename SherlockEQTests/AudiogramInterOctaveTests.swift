//
//  AudiogramInterOctaveTests.swift
//  SherlockEQTests
//
//  750 Hz and 1500 Hz joined the standard audiogram set. Profiles written
//  before that carry eight points, so the decoder fills the two gaps by
//  log-interpolation. These pin that the fill is faithful, idempotent, and
//  never overwrites a measured value — and that it interpolates rather than
//  zero-fills, which would invent normal hearing between two losses.
//

import Testing
import Foundation
@testable import SherlockEQ

@MainActor
struct AudiogramInterOctaveTests {

    private static let legacyFrequencies = [250, 500, 1000, 2000, 3000, 4000, 6000, 8000]

    /// Round-trip a profile through JSON with the two inter-octaves stripped,
    /// reproducing what an older build wrote to disk.
    private func decodedLegacy(_ thresholds: [Int: Double]) throws -> HearingProfile {
        var p = HearingProfile.makeDefault(name: "Legacy")
        let points = Self.legacyFrequencies.map {
            AudiogramPoint(frequencyHz: $0, thresholddBHL: thresholds[$0] ?? 0)
        }
        p.leftEar.thresholds = points
        p.rightEar.thresholds = points
        p.audiogramDate = Date(timeIntervalSince1970: 1_700_000_000)

        var json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(p)) as! [String: Any]
        // Belt and braces: strip 750/1500 from the encoded arrays so the
        // fixture can't accidentally carry them.
        for ear in ["leftEar", "rightEar"] {
            var e = json[ear] as! [String: Any]
            let pts = (e["thresholds"] as! [[String: Any]]).filter {
                let hz = $0["frequencyHz"] as! Int
                return hz != 750 && hz != 1500
            }
            e["thresholds"] = pts
            json[ear] = e
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(HearingProfile.self, from: data)
    }

    private func threshold(_ p: HearingProfile, _ hz: Int) -> Double? {
        p.leftEar.thresholds.first { $0.frequencyHz == hz }?.thresholddBHL
    }

    // MARK: - The set itself

    @Test func standardSetCarriesTheInterOctaves() {
        #expect(AudiogramPoint.standardFrequencies ==
                [250, 500, 750, 1000, 1500, 2000, 3000, 4000, 6000, 8000])
        #expect(AudiogramPoint.flat.count == 10)
    }

    // MARK: - Filling legacy profiles

    @Test func legacyProfileGainsBothPoints() throws {
        let p = try decodedLegacy([250: 10, 500: 20, 1000: 30, 2000: 40,
                                   3000: 50, 4000: 55, 6000: 60, 8000: 60])
        #expect(p.leftEar.thresholds.count == 10)
        #expect(p.rightEar.thresholds.count == 10)
        #expect(threshold(p, 750) != nil)
        #expect(threshold(p, 1500) != nil)
    }

    /// Log-interpolated, not linear and not zero. 750 sits between 500 (20 dB)
    /// and 1000 (30 dB); on a log axis it lands about 58 % of the way up.
    @Test func filledValuesAreLogInterpolated() throws {
        let p = try decodedLegacy([250: 10, 500: 20, 1000: 30, 2000: 40,
                                   3000: 50, 4000: 55, 6000: 60, 8000: 60])
        let at750 = try #require(threshold(p, 750))
        let at1500 = try #require(threshold(p, 1500))
        // Strictly between its neighbours, nearer the upper one.
        #expect(at750 > 20 && at750 < 30)
        #expect(at750 > 25, "log spacing puts 750 past the midpoint of 500…1000")
        #expect(at1500 > 30 && at1500 < 40)
        #expect(at1500 > 35)
    }

    /// The trap this design avoids: zero-filling would put perfect hearing
    /// between two losses and prescribe a dip to match a notch that isn't
    /// there.
    @Test func filledValuesAreNeverZeroOnALossyAudiogram() throws {
        let p = try decodedLegacy([250: 40, 500: 45, 1000: 50, 2000: 55,
                                   3000: 60, 4000: 60, 6000: 65, 8000: 65])
        #expect(try #require(threshold(p, 750)) >= 45)
        #expect(try #require(threshold(p, 1500)) >= 50)
    }

    /// A never-entered audiogram is flat zero throughout, so the fill produces
    /// exactly `AudiogramPoint.flat` — which is what keeps factory presets
    /// matching their canonical definition instead of reading as edited.
    @Test func flatAudiogramStaysFlatAndPristine() throws {
        let p = try decodedLegacy([:])
        #expect(p.leftEar.thresholds == AudiogramPoint.flat)
        #expect(!p.hasEnteredAudiogram || p.leftEar.thresholds.allSatisfy { $0.thresholddBHL == 0 })
    }

    /// Decoding twice must not shift a value — the fill has to be a no-op once
    /// the set is complete.
    @Test func fillIsIdempotent() throws {
        let once = try decodedLegacy([250: 10, 500: 20, 1000: 30, 2000: 40,
                                      3000: 50, 4000: 55, 6000: 60, 8000: 60])
        let data = try JSONEncoder().encode(once)
        let twice = try JSONDecoder().decode(HearingProfile.self, from: data)
        #expect(twice.leftEar.thresholds == once.leftEar.thresholds)
    }

    /// A real measurement at 750/1500 must survive untouched.
    @Test func measuredInterOctavesAreNotOverwritten() throws {
        var p = HearingProfile.makeDefault(name: "Measured")
        var points = AudiogramPoint.flat
        for i in points.indices where points[i].frequencyHz == 750 { points[i].thresholddBHL = 42 }
        for i in points.indices where points[i].frequencyHz == 1500 { points[i].thresholddBHL = 7 }
        p.leftEar.thresholds = points
        p.rightEar.thresholds = points

        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(HearingProfile.self, from: data)
        #expect(threshold(back, 750) == 42)
        #expect(threshold(back, 1500) == 7)
    }

    // MARK: - Prescription

    /// The added points must not change the shape of the correction on a
    /// smooth audiogram — they interpolate what the neighbours already imply,
    /// so the realised response at the measured frequencies should hold.
    @Test func prescriptionShapeSurvivesTheAddedPoints() throws {
        let byFreq: [Int: Double] = [250: 10, 500: 20, 1000: 30, 2000: 40,
                                     3000: 50, 4000: 55, 6000: 60, 8000: 60]
        let eight = Self.legacyFrequencies.map {
            AudiogramPoint(frequencyHz: $0, thresholddBHL: byFreq[$0]!)
        }
        let ten = try decodedLegacy(byFreq).leftEar.thresholds

        let a = AudiogramConversion.bands(for: eight, compensationFactor: 1.0).filter(\.enabled)
        let b = AudiogramConversion.bands(for: ten, compensationFactor: 1.0).filter(\.enabled)

        for f in [500.0, 1000, 2000, 4000, 8000] {
            let before = BiquadResponse.compositeMagnitudeDB(at: f, bands: a)
            let after = BiquadResponse.compositeMagnitudeDB(at: f, bands: b)
            #expect(abs(after - before) < 1.5,
                    "prescription moved \(abs(after - before)) dB at \(f) Hz")
        }
    }

    /// One band per audiogram point — the conversion is frequency-driven, so
    /// the two new points must actually reach the prescription.
    @Test func prescriptionGainsBandsAtTheNewFrequencies() throws {
        let p = try decodedLegacy([250: 30, 500: 35, 1000: 40, 2000: 45,
                                   3000: 50, 4000: 55, 6000: 60, 8000: 60])
        let bands = AudiogramConversion.bands(for: p.leftEar.thresholds, compensationFactor: 1.0)
        #expect(bands.contains { $0.frequencyHz == 750 })
        #expect(bands.contains { $0.frequencyHz == 1500 })
    }

    // MARK: - Interchange

    /// An imported file measuring 750/1500 now lands on its own slot instead
    /// of being snapped onto a neighbour.
    @Test func importedInterOctavesGetTheirOwnSlot() {
        let doc = AudiogramInterchange(points: [
            .init(frequencyHz: 750, leftEardBHL: 33, rightEardBHL: 33),
            .init(frequencyHz: 1500, leftEardBHL: 44, rightEardBHL: 44),
        ])
        let (left, _) = doc.perEarThresholds()
        #expect(left.first { $0.frequencyHz == 750 }?.thresholddBHL == 33)
        #expect(left.first { $0.frequencyHz == 1500 }?.thresholddBHL == 44)
        #expect(left.count == 10)
    }
}
