import SwiftUI

/// Inline warning that the active profile's headphone correction is running
/// on an output device it wasn't set up for (spec §7). Mounted in the
/// popover (below the compensation slider) and on the Equalizer screen —
/// same message, same two actions, one component.
///
/// Deliberately NOT a NoticeCenter banner: this is durable state tied to a
/// (profile, device) combination, not a transient event — it stays until
/// the user acts or the combination changes. And deliberately no auto-
/// bypass: no silent audio changes (spec Design note 5).
struct AutoEQMismatchRow: View {
    @EnvironmentObject private var audioState: AudioState
    /// Tighter paddings/typography for the 380 pt popover.
    var compact: Bool = false

    var body: some View {
        if let mismatch = audioState.autoEQMismatch {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: mismatch.currentIsBuiltInSpeakers
                          ? "speaker.zzz" : "headphones.circle")
                        .foregroundStyle(.orange)
                    Text(mismatch.message)
                        .font(compact ? .caption : .callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Bypass here") {
                        audioState.bypassAutoEQForSession()
                    }
                    .help("Turn the headphone-correction stage off for this session. The profile keeps the correction for next time.")
                    Button("Dismiss") {
                        audioState.dismissAutoEQMismatch()
                    }
                    .help("Hide this warning for this profile on this output device.")
                    Spacer()
                }
                .controlSize(compact ? .small : .regular)
            }
            .padding(compact ? 8 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.orange.opacity(0.35))
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Headphone correction device mismatch. \(mismatch.message)")
        }
    }
}
