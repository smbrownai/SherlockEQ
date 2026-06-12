import SwiftUI

/// A horizontal run of small "best-use" tag chips ("Voice", "Music",
/// "Comfort", …). Shown on factory-preset cards in the profile list,
/// Profile Detail header, and the onboarding profile picker.
struct TagChips: View {
    let tags: [String]
    var font: Font = .caption2

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(font.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.12))
                    )
            }
        }
    }
}
