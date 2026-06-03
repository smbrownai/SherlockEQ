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

    /// Index of the parametric band closest to `frequencyHz`, if it's within
    /// `matchToleranceRatio` of the target.
    static func indexOfBand(near frequencyHz: Double, in bands: [EQBand]) -> Int? {
        let tolerance = frequencyHz * matchToleranceRatio
        var best: (idx: Int, distance: Double)?
        for (idx, band) in bands.enumerated() where band.filterType == .parametric {
            let d = abs(band.frequencyHz - frequencyHz)
            if d <= tolerance, best == nil || d < best!.distance {
                best = (idx, d)
            }
        }
        return best?.idx
    }

    /// Read the gain at `frequencyHz` if a matching band exists. Returns 0
    /// when no nearby parametric band is present (the slider sits at flat).
    static func gain(at frequencyHz: Double, in bands: [EQBand]) -> Double {
        guard let idx = indexOfBand(near: frequencyHz, in: bands) else { return 0 }
        return bands[idx].gaindB
    }

    /// Set the band at `frequencyHz` to `gain`. Creates a band if none
    /// matches; removes it again if the gain returns to (near) zero so the
    /// engine doesn't waste a band slot on silent rows.
    static func setGain(
        _ gain: Double,
        at frequencyHz: Double,
        bandwidth: Double,
        in bands: inout [EQBand]
    ) {
        let trimmed = (abs(gain) < 0.01) ? 0 : gain
        if let idx = indexOfBand(near: frequencyHz, in: bands) {
            if trimmed == 0 {
                bands.remove(at: idx)
            } else {
                bands[idx].frequencyHz = frequencyHz
                bands[idx].gaindB = trimmed
                bands[idx].bandwidth = bandwidth
                bands[idx].filterType = .parametric
                bands[idx].enabled = true
            }
        } else if trimmed != 0 {
            bands.append(EQBand(
                frequencyHz: frequencyHz,
                gaindB: trimmed,
                bandwidth: bandwidth,
                filterType: .parametric,
                enabled: true
            ))
            bands.sort { $0.frequencyHz < $1.frequencyHz }
        }
    }
}
