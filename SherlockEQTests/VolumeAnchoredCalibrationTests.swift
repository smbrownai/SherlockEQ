import Foundation
import Testing
@testable import SherlockEQ

/// Pure-math coverage for the volume-anchored calibration delta — the dB
/// shift the dose pipeline applies for system-volume changes since
/// calibration time (see `volume-aware-dose.md` §5). Every rule branch of
/// `deltaDB` / `status` gets a case; the two must always agree, so most
/// assertions check both.
struct VolumeAnchoredCalibrationTests {

    private let anchor = CalibrationVolumeAnchor(volumeDB: -20, deviceUID: "AirPods-UID")

    // MARK: - Active tracking

    @Test func sameDeviceQuieterProducesNegativeDelta() {
        let delta = CalibrationVolumeAnchor.deltaDB(
            anchor: anchor, currentVolumeDB: -35, currentDeviceUID: "AirPods-UID", isMuted: false)
        #expect(delta == -15)
        #expect(CalibrationVolumeAnchor.status(
            anchor: anchor, currentVolumeDB: -35, currentDeviceUID: "AirPods-UID", isMuted: false)
            == .active(deltaDB: -15))
    }

    @Test func sameDeviceLouderProducesPositiveDelta() {
        let delta = CalibrationVolumeAnchor.deltaDB(
            anchor: anchor, currentVolumeDB: -8, currentDeviceUID: "AirPods-UID", isMuted: false)
        #expect(delta == 12)
    }

    @Test func unchangedVolumeProducesZeroDelta() {
        let delta = CalibrationVolumeAnchor.deltaDB(
            anchor: anchor, currentVolumeDB: -20, currentDeviceUID: "AirPods-UID", isMuted: false)
        #expect(delta == 0)
    }

    // MARK: - Clamping

    @Test func deltaClampsAtLowerBound() {
        // Anchor high, volume slammed to a device floor far below.
        let delta = CalibrationVolumeAnchor.deltaDB(
            anchor: CalibrationVolumeAnchor(volumeDB: 0, deviceUID: "u"),
            currentVolumeDB: -120, currentDeviceUID: "u", isMuted: false)
        #expect(delta == CalibrationVolumeAnchor.deltaClampDB.lowerBound)
    }

    @Test func deltaClampsAtUpperBound() {
        let delta = CalibrationVolumeAnchor.deltaDB(
            anchor: CalibrationVolumeAnchor(volumeDB: -80, deviceUID: "u"),
            currentVolumeDB: 0, currentDeviceUID: "u", isMuted: false)
        #expect(delta == CalibrationVolumeAnchor.deltaClampDB.upperBound)
    }

    // MARK: - Fallbacks (all must degrade to the legacy delta = 0)

    @Test func missingAnchorFallsBackToZero() {
        let delta = CalibrationVolumeAnchor.deltaDB(
            anchor: nil, currentVolumeDB: -35, currentDeviceUID: "AirPods-UID", isMuted: false)
        #expect(delta == 0)
        #expect(CalibrationVolumeAnchor.status(
            anchor: nil, currentVolumeDB: -35, currentDeviceUID: "AirPods-UID", isMuted: false)
            == .unanchored)
    }

    @Test func unreadableCurrentVolumeFallsBackToZero() {
        let delta = CalibrationVolumeAnchor.deltaDB(
            anchor: anchor, currentVolumeDB: nil, currentDeviceUID: "AirPods-UID", isMuted: false)
        #expect(delta == 0)
        #expect(CalibrationVolumeAnchor.status(
            anchor: anchor, currentVolumeDB: nil, currentDeviceUID: "AirPods-UID", isMuted: false)
            == .unavailable)
    }

    @Test func missingDeviceUIDFallsBackToZero() {
        let delta = CalibrationVolumeAnchor.deltaDB(
            anchor: anchor, currentVolumeDB: -35, currentDeviceUID: nil, isMuted: false)
        #expect(delta == 0)
        #expect(CalibrationVolumeAnchor.status(
            anchor: anchor, currentVolumeDB: -35, currentDeviceUID: nil, isMuted: false)
            == .unavailable)
    }

    @Test func deviceMismatchFallsBackToZero() {
        let delta = CalibrationVolumeAnchor.deltaDB(
            anchor: anchor, currentVolumeDB: -35, currentDeviceUID: "MacBook-Speakers", isMuted: false)
        #expect(delta == 0)
        #expect(CalibrationVolumeAnchor.status(
            anchor: anchor, currentVolumeDB: -35, currentDeviceUID: "MacBook-Speakers", isMuted: false)
            == .deviceMismatch)
    }

    // MARK: - Mute

    @Test func mutedWinsRegardlessOfAnchor() {
        // Muted output is silence at the ear; identity/anchor don't matter.
        let withAnchor = CalibrationVolumeAnchor.deltaDB(
            anchor: anchor, currentVolumeDB: -8, currentDeviceUID: "AirPods-UID", isMuted: true)
        let withoutAnchor = CalibrationVolumeAnchor.deltaDB(
            anchor: nil, currentVolumeDB: nil, currentDeviceUID: nil, isMuted: true)
        #expect(withAnchor == CalibrationVolumeAnchor.mutedDeltaDB)
        #expect(withoutAnchor == CalibrationVolumeAnchor.mutedDeltaDB)
        #expect(CalibrationVolumeAnchor.status(
            anchor: anchor, currentVolumeDB: -8, currentDeviceUID: "AirPods-UID", isMuted: true)
            == .muted)
    }

    @Test @MainActor func mutedDeltaSilencesNIOSHAccumulation() {
        // Even a hot calibration (115 dB SPL @ 0 dBFS) lands at an effective
        // level whose permissible duration is astronomically long — the dose
        // contribution while muted is negligible by construction.
        let effectiveDBA = 115 + CalibrationVolumeAnchor.mutedDeltaDB   // −5 dBA
        let perm = SafeListeningTracker.permissibleDuration(at: max(0, effectiveDBA))
        #expect(perm > 100 * 365 * 24 * 3600)   // > a century
    }

    // MARK: - Garbage in, legacy behavior out

    @Test func nonFiniteInputsFallBackSafely() {
        #expect(CalibrationVolumeAnchor.deltaDB(
            anchor: CalibrationVolumeAnchor(volumeDB: .nan, deviceUID: "u"),
            currentVolumeDB: -10, currentDeviceUID: "u", isMuted: false) == 0)
        #expect(CalibrationVolumeAnchor.deltaDB(
            anchor: anchor, currentVolumeDB: .infinity, currentDeviceUID: "AirPods-UID",
            isMuted: false) == 0)
        #expect(CalibrationVolumeAnchor.deltaDB(
            anchor: anchor, currentVolumeDB: .nan, currentDeviceUID: "AirPods-UID",
            isMuted: false) == 0)
    }
}
