import Foundation

/// Shared helpers used by the Simple and Advanced EQ tabs. Both are
/// "convenience views" onto the same per-ear `[EQBand]` array — they edit
/// whatever parametric band lives at (or near) a target frequency, creating
/// one with neutral gain if none exists yet. This means moves in Simple
/// show up in Advanced and Expert and vice-versa.
enum EQBandLookup {
    /// Tolerance for treating an existing band's frequency as "matching" a
    /// target slot. 1/12 octave on either side.
    static let matchToleranceRatio: Double = 1.0594631 - 1.0  // 2^(1/12) − 1

    /// Index of the band of `filterType` closest to `frequencyHz` if it's
    /// within tolerance. Filter-type-aware so Simple's low-shelf Bass at
    /// 250 Hz doesn't collide with Advanced's parametric 250 Hz peak.
    static func indexOfBand(
        near frequencyHz: Double,
        filterType: EQFilterType,
        in bands: [EQBand]
    ) -> Int? {
        let tolerance = frequencyHz * matchToleranceRatio
        var best: (idx: Int, distance: Double)?
        for (idx, band) in bands.enumerated() where band.filterType == filterType {
            let d = abs(band.frequencyHz - frequencyHz)
            if d <= tolerance, best == nil || d < best!.distance {
                best = (idx, d)
            }
        }
        return best?.idx
    }

    /// Read the gain at `frequencyHz` for a band of `filterType`.
    static func gain(
        at frequencyHz: Double,
        filterType: EQFilterType,
        in bands: [EQBand]
    ) -> Double {
        guard let idx = indexOfBand(near: frequencyHz, filterType: filterType, in: bands) else { return 0 }
        return bands[idx].gaindB
    }

    /// Set the band at `frequencyHz` of `filterType` to `gain`. Creates if
    /// missing; removes if the gain returns to ~0 so engine slots stay
    /// clear of silent rows.
    static func setGain(
        _ gain: Double,
        at frequencyHz: Double,
        bandwidth: Double,
        filterType: EQFilterType,
        in bands: inout [EQBand]
    ) {
        let trimmed = (abs(gain) < 0.01) ? 0 : gain
        if let idx = indexOfBand(near: frequencyHz, filterType: filterType, in: bands) {
            if trimmed == 0 {
                bands.remove(at: idx)
            } else {
                bands[idx].frequencyHz = frequencyHz
                bands[idx].gaindB = trimmed
                bands[idx].bandwidth = bandwidth
                bands[idx].filterType = filterType
                bands[idx].enabled = true
            }
        } else if trimmed != 0 {
            bands.append(EQBand(
                frequencyHz: frequencyHz,
                gaindB: trimmed,
                bandwidth: bandwidth,
                filterType: filterType,
                enabled: true
            ))
            bands.sort { $0.frequencyHz < $1.frequencyHz }
        }
    }
}
