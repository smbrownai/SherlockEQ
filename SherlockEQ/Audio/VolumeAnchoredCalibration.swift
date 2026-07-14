import Foundation

/// The volume anchor recorded when the user sets the SPL calibration, plus
/// the pure math that turns a live volume reading into a dB shift on the
/// effective calibration offset. See `volume-aware-dose.md`.
///
/// The problem this solves: CATap captures audio *upstream* of the hardware
/// volume control, so `dBA = dBFS + calibrationOffsetDBA` is only right at
/// the volume the user calibrated at. Anchoring the calibration to that
/// volume and shifting by the live delta makes the dose estimate follow the
/// volume keys:
///
///     effectiveOffset = calibrationOffsetDBA + deltaDB(...)
///
/// Every unreadable/mismatched condition degrades to `0` — exactly the
/// legacy fixed-offset behavior. The feature can only add information.
struct CalibrationVolumeAnchor: Equatable, Codable {
    /// Output volume in dB at the moment the calibration was set.
    var volumeDB: Double
    /// UID of the output device the calibration was measured on. A delta
    /// against a *different* device is meaningless — different hardware
    /// means the SPL anchor itself is stale, not just the volume.
    var deviceUID: String
}

extension CalibrationVolumeAnchor {

    /// dB applied in place of any real delta while the output is muted:
    /// muted output is silence at the ear, so the effective level drops to
    /// the tracker's floor and NIOSH accumulation is ~0.
    static let mutedDeltaDB: Double = -120

    /// Sanity clamp on the live delta. Wide enough never to bind in real
    /// use — it exists to stop NaN/garbage HAL reads from distorting the
    /// dose, not to limit legitimate volume swings. The top is generous
    /// because *under*-counting loud conditions is the harm this feature
    /// fixes.
    static let deltaClampDB: ClosedRange<Double> = -80 ... 40

    /// Volume-tracking condition, for the Safe Listening status row. Derived
    /// from the same inputs as `deltaDB` so UI copy and dose math can't
    /// disagree.
    enum Status: Equatable {
        /// Tracking: the effective calibration currently includes `deltaDB`.
        case active(deltaDB: Double)
        /// Output muted — no exposure accumulating.
        case muted
        /// No anchor recorded (legacy install, or the volume was unreadable
        /// when the calibration was last set).
        case unanchored
        /// The current device exposes no readable volume (HDMI, optical,
        /// some aggregates) — falling back to the calibration-time volume.
        case unavailable
        /// Default output changed since calibration — the anchor belongs to
        /// different hardware; recalibrate to re-anchor.
        case deviceMismatch
    }

    /// The dB shift to apply to the calibration offset for the current
    /// volume state. Rules in priority order (see `volume-aware-dose.md` §5).
    static func deltaDB(
        anchor: CalibrationVolumeAnchor?,
        currentVolumeDB: Double?,
        currentDeviceUID: String?,
        isMuted: Bool
    ) -> Double {
        switch status(anchor: anchor,
                      currentVolumeDB: currentVolumeDB,
                      currentDeviceUID: currentDeviceUID,
                      isMuted: isMuted) {
        case .active(let delta): return delta
        case .muted:             return mutedDeltaDB
        case .unanchored, .unavailable, .deviceMismatch: return 0
        }
    }

    static func status(
        anchor: CalibrationVolumeAnchor?,
        currentVolumeDB: Double?,
        currentDeviceUID: String?,
        isMuted: Bool
    ) -> Status {
        if isMuted { return .muted }
        guard let anchor, anchor.volumeDB.isFinite else { return .unanchored }
        guard let currentVolumeDB, currentVolumeDB.isFinite,
              let currentDeviceUID else { return .unavailable }
        guard currentDeviceUID == anchor.deviceUID else { return .deviceMismatch }
        let raw = currentVolumeDB - anchor.volumeDB
        guard raw.isFinite else { return .unavailable }
        return .active(deltaDB: min(deltaClampDB.upperBound,
                                    max(deltaClampDB.lowerBound, raw)))
    }
}
