//
//  VUMeterCalibrationTests.swift
//  SherlockEQTests
//
//  The analog VU meters reference 0 VU to the user's comfortable listening
//  level (AudioState.vuZeroAnchorDBA, 70 dBA) via the calibration offset,
//  so the needle reads at-ear loudness (dBA − 70) rather than raw digital
//  level. These tests pin that mapping — and the regression it fixes, where
//  quiet / loudness-normalized program material pinned the needle at the
//  dial floor no matter how loud the user was actually listening.
//

import Testing
import Foundation
@testable import SherlockEQ

struct VUMeterCalibrationTests {

    /// Run the ballistics to steady state for a constant rms.
    private func steadyVU(rms: Double, referenceDBFS: Double) -> Double {
        var s = VUBallisticsState()
        // 4 s at 50 Hz is far past the 300 ms rise time; the critically-
        // damped integrator has fully settled onto its target.
        for _ in 0..<200 { s.update(rms: rms, referenceDBFS: referenceDBFS, dt: 0.02) }
        return s.vu
    }

    /// dBFS (RMS, full-scale = 0) → linear amplitude.
    private func amplitude(dbfs: Double) -> Double { pow(10, dbfs / 20) }

    /// The comfortable-listening reference AudioState derives: 0 VU sits at
    /// the digital level that lands at the 70 dBA anchor for a given offset.
    private func comfortReference(offsetDBA: Double) -> Double {
        AudioState.vuZeroAnchorDBA - offsetDBA
    }

    @Test func anchorIsSeventyDBA() {
        #expect(AudioState.vuZeroAnchorDBA == 70)
    }

    @Test func listeningAtTheAnchorLevelReadsZeroVU() {
        // Offset 100 dBA: 0 dBFS = 100 dB SPL. The digital level that lands
        // at 70 dBA at the ear is −30 dBFS. Fed that, the needle sits at 0 VU.
        let offset = 100.0
        let ref = comfortReference(offsetDBA: offset)          // −30 dBFS
        let rmsAt70 = amplitude(dbfs: 70 - offset)             // −30 dBFS
        #expect(abs(steadyVU(rms: rmsAt70, referenceDBFS: ref)) < 0.1)
    }

    @Test func needleTracksAtEarLoudnessMinusSeventy() {
        // For any at-ear level, VU == atEarDBA − 70, independent of the
        // digital mastering level (the offset cancels out).
        let offset = 100.0
        let ref = comfortReference(offsetDBA: offset)
        for atEar in [55.0, 62.0, 70.0, 73.0] {
            let rms = amplitude(dbfs: atEar - offset)
            let vu = steadyVU(rms: rms, referenceDBFS: ref)
            #expect(abs(vu - (atEar - 70)) < 0.1, "atEar \(atEar) → VU \(vu), expected \(atEar - 70)")
        }
    }

    @Test func differentCalibrationSameAtEarLevelReadsSameVU() {
        // A quieter digital master (lower offset needs more level) and a
        // hotter one land at the same VU when the at-ear loudness matches —
        // the whole point: VU follows loudness, not digital level.
        let atEar = 68.0
        let a = steadyVU(rms: amplitude(dbfs: atEar - 90),  referenceDBFS: comfortReference(offsetDBA: 90))
        let b = steadyVU(rms: amplitude(dbfs: atEar - 110), referenceDBFS: comfortReference(offsetDBA: 110))
        #expect(abs(a - b) < 0.1)
        #expect(abs(a - (atEar - 70)) < 0.1)
    }

    @Test func quietMasterNoLongerPinsTheFloorWhenListenedAtComfort() {
        // Regression. A −45 dBFS RMS signal (a quiet / normalized master).
        // Old behaviour: fixed −18 dBFS reference → VU = −45 − (−18) = −27,
        // clamped to the −20 dial floor: the needle is pinned regardless of
        // how loud the user is actually listening.
        let quietMasterRMS = amplitude(dbfs: -45)
        let oldVU = steadyVU(rms: quietMasterRMS, referenceDBFS: -18)   // ≈ −27 VU
        #expect(oldVU <= VUScale.ticks.first!.vu)                       // below the dial's lowest mark (−20)
        #expect(VUScale.frac(forVU: oldVU) == VUScale.ticks.first!.frac)  // pinned at the bottom of the dial

        // New behaviour: if that same −45 dBFS master is being listened to at
        // 70 dBA (i.e. the calibration offset is 115 so −45 dBFS → 70 dBA),
        // the needle sits at 0 VU — mid-dial, reading the actual loudness.
        let offset = 115.0                                            // −45 dBFS = 70 dBA
        let newVU = steadyVU(rms: quietMasterRMS, referenceDBFS: comfortReference(offsetDBA: offset))
        #expect(abs(newVU) < 0.1)
        #expect(abs(VUScale.frac(forVU: newVU) - VUScale.zeroFrac) < 0.001)  // at the 0 mark
    }
}
