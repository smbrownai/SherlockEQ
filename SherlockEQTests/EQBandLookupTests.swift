//
//  EQBandLookupTests.swift
//  SherlockEQTests
//
//  The find-or-create-near-frequency machinery shared by Simple, Speech,
//  Advanced, and Expert EQ views. Bug here corrupts every user's profile
//  state — slider drags would touch wrong bands.
//

import Testing
import Foundation
@testable import SherlockEQ

struct EQBandLookupTests {

    private static func band(
        hz: Double,
        gainDB: Double,
        Q: Double = 1.0,
        type: EQFilterType = .parametric,
        enabled: Bool = true
    ) -> EQBand {
        EQBand(
            frequencyHz: hz,
            gaindB: gainDB,
            bandwidth: Q,
            filterType: type,
            enabled: enabled
        )
    }

    // MARK: - indexOfBand tolerance

    @Test func findsExactFrequencyMatch() {
        let chain = [Self.band(hz: 1000, gainDB: 3)]
        #expect(EQBandLookup.indexOfBand(near: 1000, filterType: .parametric, in: chain) == 0)
    }

    @Test func findsWithinTolerance() {
        // matchToleranceRatio = 2^(1/12) − 1 ≈ 0.0595, so 1000 Hz ± ~59 Hz.
        let chain = [Self.band(hz: 1000, gainDB: 3)]
        #expect(EQBandLookup.indexOfBand(near: 1040, filterType: .parametric, in: chain) == 0)
        #expect(EQBandLookup.indexOfBand(near: 960,  filterType: .parametric, in: chain) == 0)
    }

    @Test func skipsOutsideTolerance() {
        let chain = [Self.band(hz: 1000, gainDB: 3)]
        #expect(EQBandLookup.indexOfBand(near: 1200, filterType: .parametric, in: chain) == nil)
        #expect(EQBandLookup.indexOfBand(near: 800,  filterType: .parametric, in: chain) == nil)
    }

    @Test func filterTypeIsolatesShelfFromParametric() {
        // Simple's low-shelf @ 250 Hz must NOT collide with Advanced's
        // parametric @ 250 Hz — they're independent slots, same Hz.
        let chain = [
            Self.band(hz: 250, gainDB: 3, type: .lowShelf),
            Self.band(hz: 250, gainDB: -2, type: .parametric),
        ]
        let shelfIdx     = EQBandLookup.indexOfBand(near: 250, filterType: .lowShelf,    in: chain)
        let parametricIdx = EQBandLookup.indexOfBand(near: 250, filterType: .parametric, in: chain)
        #expect(shelfIdx == 0)
        #expect(parametricIdx == 1)
        #expect(shelfIdx != parametricIdx)
    }

    @Test func picksClosestWhenMultipleInTolerance() {
        // 980 and 1010 are both within tolerance of 1000; closer wins.
        let chain = [
            Self.band(hz: 980,  gainDB: 1),
            Self.band(hz: 1010, gainDB: 2),
        ]
        let idx = EQBandLookup.indexOfBand(near: 1000, filterType: .parametric, in: chain)
        #expect(idx == 1, "1010 is closer to 1000 than 980; got index \(idx ?? -1)")
    }

    // MARK: - gain reader

    @Test func gainReturnsZeroForUnknownFrequency() {
        let chain = [Self.band(hz: 1000, gainDB: 6)]
        #expect(EQBandLookup.gain(at: 2000, filterType: .parametric, in: chain) == 0)
    }

    @Test func gainReturnsStoredValue() {
        let chain = [Self.band(hz: 1000, gainDB: 4.5)]
        #expect(EQBandLookup.gain(at: 1000, filterType: .parametric, in: chain) == 4.5)
    }

    // MARK: - setGain create / update / remove

    @Test func setGainCreatesNewBand() {
        var chain: [EQBand] = []
        EQBandLookup.setGain(6, at: 1000, bandwidth: 1.0, filterType: .parametric, in: &chain)
        #expect(chain.count == 1)
        #expect(chain[0].frequencyHz == 1000)
        #expect(chain[0].gaindB == 6)
        #expect(chain[0].enabled)
    }

    @Test func setGainUpdatesExistingBand() {
        var chain = [Self.band(hz: 1000, gainDB: 3)]
        EQBandLookup.setGain(-2, at: 1000, bandwidth: 1.0, filterType: .parametric, in: &chain)
        #expect(chain.count == 1)
        #expect(chain[0].gaindB == -2)
    }

    @Test func setGainZeroRemovesBand() {
        // EQBandLookup's contract: setGain(0, ...) drops the slot so the
        // engine slot can be reused. Any |gain| < 0.01 also rounds to 0.
        var chain = [Self.band(hz: 1000, gainDB: 3)]
        EQBandLookup.setGain(0, at: 1000, bandwidth: 1.0, filterType: .parametric, in: &chain)
        #expect(chain.isEmpty)
    }

    @Test func setGainTinyValueRoundsToZeroAndRemoves() {
        var chain = [Self.band(hz: 1000, gainDB: 3)]
        EQBandLookup.setGain(0.005, at: 1000, bandwidth: 1.0, filterType: .parametric, in: &chain)
        #expect(chain.isEmpty)
    }

    @Test func setGainKeepsBandsSortedByFrequency() {
        var chain: [EQBand] = []
        EQBandLookup.setGain(3, at: 4000, bandwidth: 1.0, filterType: .parametric, in: &chain)
        EQBandLookup.setGain(3, at: 100,  bandwidth: 1.0, filterType: .parametric, in: &chain)
        EQBandLookup.setGain(3, at: 1000, bandwidth: 1.0, filterType: .parametric, in: &chain)
        #expect(chain.map(\.frequencyHz) == [100, 1000, 4000])
    }

    @Test func setGainDoesNotCreateForZeroGain() {
        // No existing band + new gain = 0 → no-op, no slot allocation.
        var chain: [EQBand] = []
        EQBandLookup.setGain(0, at: 1000, bandwidth: 1.0, filterType: .parametric, in: &chain)
        #expect(chain.isEmpty)
    }

    // MARK: - mutateBands / mutateBothEars

    @Test func mutateBandsLinkedTouchesBothEars() {
        var profile = HearingProfile.makeDefault()
        EQBandLookup.mutateBands(of: &profile, ear: .left, linkChannels: true) { bands in
            EQBandLookup.setGain(5, at: 1000, bandwidth: 1.0, filterType: .parametric, in: &bands)
        }
        let leftGain  = EQBandLookup.gain(at: 1000, filterType: .parametric, in: profile.leftEar.bands)
        let rightGain = EQBandLookup.gain(at: 1000, filterType: .parametric, in: profile.rightEar.bands)
        #expect(leftGain == 5)
        #expect(rightGain == 5)
    }

    @Test func mutateBandsUnlinkedTouchesOnlyAddressedEar() {
        var profile = HearingProfile.makeDefault()
        EQBandLookup.mutateBands(of: &profile, ear: .left, linkChannels: false) { bands in
            EQBandLookup.setGain(5, at: 1000, bandwidth: 1.0, filterType: .parametric, in: &bands)
        }
        let leftGain  = EQBandLookup.gain(at: 1000, filterType: .parametric, in: profile.leftEar.bands)
        let rightGain = EQBandLookup.gain(at: 1000, filterType: .parametric, in: profile.rightEar.bands)
        #expect(leftGain == 5)
        #expect(rightGain == 0)
    }

    @Test func mutateBandsUnlinkedRightOnly() {
        var profile = HearingProfile.makeDefault()
        EQBandLookup.mutateBands(of: &profile, ear: .right, linkChannels: false) { bands in
            EQBandLookup.setGain(-3, at: 4000, bandwidth: 1.0, filterType: .parametric, in: &bands)
        }
        let leftGain  = EQBandLookup.gain(at: 4000, filterType: .parametric, in: profile.leftEar.bands)
        let rightGain = EQBandLookup.gain(at: 4000, filterType: .parametric, in: profile.rightEar.bands)
        #expect(leftGain == 0)
        #expect(rightGain == -3)
    }

    @Test func mutateBothEarsTouchesBoth() {
        // Used by preset/reset flows — should touch both ears
        // regardless of any link-channels state.
        var profile = HearingProfile.makeDefault()
        EQBandLookup.mutateBothEars(of: &profile) { bands in
            EQBandLookup.setGain(2, at: 250, bandwidth: 1.0, filterType: .lowShelf, in: &bands)
        }
        let leftShelf  = EQBandLookup.gain(at: 250, filterType: .lowShelf, in: profile.leftEar.bands)
        let rightShelf = EQBandLookup.gain(at: 250, filterType: .lowShelf, in: profile.rightEar.bands)
        #expect(leftShelf == 2)
        #expect(rightShelf == 2)
    }
}
