import SwiftUI

/// Discoverability surface for the single-EQ-mode model. The four EQ
/// tabs are storage views onto one underlying band array, so switching
/// `profile.eqMode` from (say) Expert to Simple hides any bands that
/// don't fall in Simple's three owned slots. The bands aren't gone —
/// they keep applying to the audio chain — they just aren't editable
/// from the current view. This chip surfaces that fact when relevant
/// and offers a one-click jump to Expert (which sees every band).
///
/// Counts both ears together; bands that are audibly equivalent on
/// the two ears collapse to one for the count so a linked-mode
/// profile with 3 Expert bands per ear reads as "3 bands hidden"
/// rather than "6."
struct HiddenBandsHintChip: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var audioState: AudioState

    var body: some View {
        if let profile = audioState.activeProfile(in: profileStore),
           profile.eqMode != .expert {
            let count = hiddenBandCount(in: profile)
            if count > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.stack.badge.minus")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(count) band\(count == 1 ? "" : "s") hidden in \(profile.eqMode.label) mode")
                            .font(.caption.weight(.semibold))
                        Text("These bands still apply to the audio. Switch to Expert to see and edit them.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Switch to Expert") {
                        var updated = profile
                        updated.eqMode = .expert
                        try? profileStore.save(updated)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                )
            }
        }
    }

    /// Hidden-band count: union of `leftEar` and `rightEar` hidden
    /// bands, deduplicated by `audiblySame` so symmetric profiles
    /// don't double-count.
    private func hiddenBandCount(in profile: HearingProfile) -> Int {
        let leftHidden = profile.eqMode.hiddenBands(in: profile.leftEar.bands)
        let rightHidden = profile.eqMode.hiddenBands(in: profile.rightEar.bands)
        var unique: [EQBand] = []
        for band in leftHidden + rightHidden {
            if !unique.contains(where: { $0.audiblySame(as: band) }) {
                unique.append(band)
            }
        }
        return unique.count
    }
}
