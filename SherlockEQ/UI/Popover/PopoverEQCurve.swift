import SwiftUI

/// A small read-only EQ response curve for the popover — "what is my EQ
/// actually doing right now", answered without opening a window.
///
/// Strictly a display. `readOnly: true` and a constant band binding mean
/// there is no write path here at all: every edit still happens on the
/// Equalizer screen, which is the same report-don't-edit rule the
/// Processing details rows follow.
///
/// **Layers are hardcoded, deliberately.** The Equalizer screens drive their
/// overlays from shared `@AppStorage` keys (`sherlockeq.layer.*`), and the
/// popover has no chip strip to change them. Inheriting those keys would mean
/// a user who switched the main screen to, say, Manual-EQ-only later opens the
/// popover to a graph that looks empty or wrong, with nothing here to fix it.
/// So this view pins Result + Output: the heard result over the live output
/// spectrum, which is the one combination that always answers the question.
struct PopoverEQCurve: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore

    /// `LiveParametricCanvas` requires a selection binding for its editing
    /// affordances. Read-only mode never writes it; this exists to satisfy
    /// the signature.
    @State private var unusedSelection: UUID? = nil

    var body: some View {
        if let profile = audioState.activeProfile(in: profileStore) {
            let correction = profile.effectiveCorrectionBands()
            VStack(alignment: .leading, spacing: 4) {
                LiveParametricCanvas(
                    spectrum: audioState.spectrum,
                    preSpectrum: audioState.preSpectrum,
                    // Constant: the popover never edits bands.
                    bands: .constant(profile.leftEar.bands),
                    shadowBands: profile.rightEar.bands,
                    targetBands: correction.left,
                    shadowTargetBands: correction.right,
                    notch: profile.leftNotch,
                    shadowNotch: profile.rightNotch,
                    spectrumSampleRate: audioState.audio.outputSampleRate ?? 48_000,
                    earColor: audioState.preferences.leftEarColor,
                    shadowColor: audioState.preferences.rightEarColor,
                    readOnly: true,
                    selectedBandID: $unusedSelection,
                    // --- Hardcoded layer set (see the type's doc comment) ---
                    showInputSpectrum: false,
                    showOutputSpectrum: true,
                    showEQCurve: false,
                    showAudiogramTarget: false,
                    showResultCurve: true,
                    showSafetyOverlay: false,
                    showNotch: true,
                    safetyCeilingDBA: profile.safeListeningCeilingDB,
                    calibrationOffsetDBA: audioState.effectiveCalibrationOffsetDBA
                )
                // Height is set by the dB axis, not by taste. The canvas
                // labels every 6 dB across ±18 (seven labels) and clamps the
                // outermost two into a 12 pt safe area so they aren't cropped,
                // which eats the gap to their neighbours: the +18↔+12 spacing
                // works out to `height/6 − 12`. At 110 they overlapped
                // outright; at 140 they still crowded. 170 gives ~16 pt, which
                // clears the ~13 pt label. Shrinking this needs a thinner axis
                // on the shared canvas, not a smaller frame here.
                //
                // Keeping the full ±18 (rather than ±12, which would space the
                // labels comfortably at any height) is deliberate: the Result
                // curve sums the hearing adjustment — per-band ceiling +20 dB —
                // on top of the manual bands, so a ±12 window would clip the
                // boost for exactly the hearing-loss users this curve is for,
                // and a flattened-against-the-ceiling curve understates it.
                .frame(height: 170)
                // The canvas draws its own Left/Right key, but only when the
                // two ears actually differ. When they match, one line is the
                // whole story and a key would be noise — so this caption
                // carries the "which ear am I looking at" answer in the
                // asymmetric case only, matching the canvas's own rule.
                earKeyCaption(profile)
            }
        }
    }

    /// Names what the curve is, and — when the ears differ — that both are
    /// drawn. Colour is never the only signal: the canvas's own legend pairs
    /// each hue with the word "Left"/"Right", and this line says it in text.
    @ViewBuilder
    private func earKeyCaption(_ profile: HearingProfile) -> some View {
        Text(earsDiffer(profile)
             ? "Your result over the live output — left and right differ."
             : "Your result over the live output.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(
                earsDiffer(profile)
                    ? "EQ response curve, showing your heard result over the live output spectrum. Left and right ears differ, so both curves are drawn."
                    : "EQ response curve, showing your heard result over the live output spectrum."
            )
    }

    /// Mirrors the canvas's own asymmetry test: the drawn curve splits in two
    /// when either the manual bands or the hearing adjustment differ per ear.
    private func earsDiffer(_ profile: HearingProfile) -> Bool {
        let correction = profile.effectiveCorrectionBands()
        return !profile.leftEar.bands.audiblyEquivalent(to: profile.rightEar.bands)
            || !correction.left.audiblyEquivalent(to: correction.right)
            || profile.leftNotch != profile.rightNotch
    }
}
