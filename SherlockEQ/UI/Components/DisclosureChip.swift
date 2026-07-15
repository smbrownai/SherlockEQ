import SwiftUI

/// Compact, consistent replacement for the repeated "not a medical device"
/// cards. Reads "Consumer audio tools — not medical care. Health & Safety…"
/// and the whole chip opens the consolidated `HealthSafetySheet`. Copy comes
/// from `HealthSafetyDisclosure` so every instance stays identical.
struct HealthSafetyChip: View {
    @EnvironmentObject private var audioState: AudioState

    var body: some View {
        Button {
            audioState.showHealthSafety = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "heart.text.square")
                    .foregroundStyle(.secondary)
                Text(HealthSafetyDisclosure.chipLead)
                    .foregroundStyle(.secondary)
                Text(HealthSafetyDisclosure.chipAction)
                    .foregroundStyle(.tint)
                    .fontWeight(.medium)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Health & Safety — what SherlockEQ is and isn't, and when to seek professional help.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(HealthSafetyDisclosure.chipLead) Open Health & Safety.")
        .accessibilityAddTraits(.isButton)
    }
}

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
                        audioState.showHealthSafety = true
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
