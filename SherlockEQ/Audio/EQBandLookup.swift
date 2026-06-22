import Foundation

/// Shared helpers used by the Simple, Speech, and Advanced EQ tabs. All
/// three are "convenience views" onto the same per-ear `[EQBand]` array
/// — they edit whatever parametric band lives at (or near) a target
/// frequency, creating one with neutral gain if none exists yet. This
/// means moves in Simple show up in Advanced and Expert and vice-versa.
enum EQBandLookup {

    /// Which ear a UI gesture addresses. Single enum instead of one
    /// per view (Simple/Speech used `Ear`, Advanced used `Channel`)
    /// so all three can route through the same mutation helpers below.
    enum Ear { case left, right }

    /// Mutate one or both ears of `profile` according to `linkChannels`.
    /// When linked, `mutation` runs against both ears so an edit in the
    /// addressed ear is mirrored to the other. When unlinked, only the
    /// addressed ear is touched.
    static func mutateBands(
        of profile: inout HearingProfile,
        ear: Ear,
        linkChannels: Bool,
        _ mutation: (inout [EQBand]) -> Void
    ) {
        if linkChannels {
            mutateBothEars(of: &profile, mutation)
        } else {
            switch ear {
            case .left:  mutation(&profile.leftEar.bands)
            case .right: mutation(&profile.rightEar.bands)
            }
        }
    }

    /// Run `mutation` against both ears unconditionally. Used by
    /// "apply preset" and "reset" flows, which target the whole
    /// profile regardless of the per-ear linking toggle.
    static func mutateBothEars(
        of profile: inout HearingProfile,
        _ mutation: (inout [EQBand]) -> Void
    ) {
        mutation(&profile.leftEar.bands)
        mutation(&profile.rightEar.bands)
    }

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

    /// Merge audiogram-derived parametric bands into an existing per-ear chain.
    /// Replaces only the parametric slots the audiogram owns (its measured
    /// frequencies, within tolerance) and preserves every other band — shelves,
    /// notches, and parametric bands at non-audiogram frequencies authored in
    /// the Simple/Speech/Advanced/Expert tabs. Editing the audiogram therefore
    /// updates its own bands without wiping the user's manual EQ work, matching
    /// the app's "switching modes is non-destructive" contract.
    static func mergingAudiogramBands(
        _ derived: [EQBand],
        into existing: [EQBand]
    ) -> [EQBand] {
        var result = existing.filter { band in
            // Keep anything that isn't a parametric band sitting on an
            // audiogram slot; those slots are the audiogram's to own.
            guard band.filterType == .parametric else { return true }
            return !derived.contains { d in
                abs(band.frequencyHz - d.frequencyHz) <= d.frequencyHz * matchToleranceRatio
            }
        }
        result.append(contentsOf: derived)
        result.sort { $0.frequencyHz < $1.frequencyHz }
        return result
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
