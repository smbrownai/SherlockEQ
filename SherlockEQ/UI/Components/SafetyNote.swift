import SwiftUI

// HealthSafetyChip used to live here — the per-screen "not medical care"
// strip. Every mount was removed once the persistent sidebar Health & Safety
// item landed (PR #129), leaving the struct unreachable; deleted in the
// audit's dead-code pass (DC-02).

/// A just-in-time safety notice: one or two sentences of timing-relevant
/// caution plus a "Learn more" link into the Health & Safety sheet. For
/// moments where a user action could immediately cause discomfort or a
/// misleading health interpretation — test tones, big boosts, calibration,
/// uncalibrated level estimates, applying audiogram adjustments.
struct SafetyNote: View {
    @EnvironmentObject private var audioState: AudioState

    let text: String
    /// SF Symbol for the leading cue (still meaningful without color).
    var symbol: String = "exclamationmark.triangle"
    /// Tint for the icon + accents. Text stays full-contrast so meaning never
    /// depends on color.
    var tint: Color = .orange
    /// When set, "Learn more" opens this Help article instead of the sheet.
    var learnMoreTopic: HelpTopic? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    if let topic = learnMoreTopic {
                        HelpCenter.shared.open(topic: topic)
                    } else {
                        // Navigate to the Health & Safety page rather than
                        // presenting it over the current screen. The note
                        // itself stays the contextual warning; "Learn more"
                        // is a trip to the reference, not an interruption.
                        audioState.pendingMainSection = .healthSafety
                    }
                } label: {
                    Text("Learn more")
                        .font(.callout)
                }
                .buttonStyle(.link)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.10)))
        .accessibilityElement(children: .combine)
    }
}
