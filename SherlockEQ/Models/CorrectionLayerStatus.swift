import Foundation

/// Which correction layers are *audible right now* — as opposed to merely
/// configured on the profile.
///
/// The distinction has bitten once already: the Graphic screen's "included in
/// Result" banner tested whether a profile had AutoEQ bands stored, so it kept
/// claiming a headphone correction was in the Result while the chain's AutoEQ
/// toggle was bypassing it. A profile can carry a full correction that nothing
/// is applying.
///
/// These rules mirror `AudioState.applyBypassMask`, which is the engine's
/// actual behavior:
/// - master off → every stage drops, *including* the audiogram correction
/// - AutoEQ toggle off → the headphone bands drop on their own
/// - the manual-EQ toggle deliberately does **not** appear here: it flattens
///   only the tone shaping on top, leaving corrections running
///
/// Pure and `nonisolated` so any surface that needs to describe the chain can
/// ask the same question and get the same answer, and so the truth table is
/// testable without standing up an audio engine.
nonisolated struct CorrectionLayerStatus: Equatable {

    /// The audiogram-derived (NAL-R) correction is being applied.
    let audiogram: Bool
    /// The headphone (AutoEQ) correction is being applied.
    let headphone: Bool

    var any: Bool { audiogram || headphone }

    init(profile: HearingProfile, masterEnabled: Bool, autoEQEnabled: Bool) {
        let hasAudiogramBands = !profile.leftEar.correctionBands.isEmpty
            || !profile.rightEar.correctionBands.isEmpty
        let hasHeadphoneBands = !(profile.autoEQBands?.isEmpty ?? true)
        self.audiogram = masterEnabled && hasAudiogramBands
        self.headphone = masterEnabled && autoEQEnabled && hasHeadphoneBands
    }

    /// Human-readable names of the active layers, low-level first — the order
    /// they sit in the cascade.
    var sourceNames: [String] {
        var names: [String] = []
        if audiogram { names.append(String(localized: "Hearing adjustment")) }
        if headphone { names.append(String(localized: "headphone correction")) }
        return names
    }
}
