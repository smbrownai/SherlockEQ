import SwiftUI

/// Banner shown above any editor when the profile being edited is a
/// curated built-in (`isBuiltIn == true`). Explains why the controls are
/// disabled and offers a Duplicate button; the parent decides what
/// "duplicate" means in its context (save + select + activate vs just
/// save + activate).
struct BuiltInProfileBanner: View {
    let profileName: String
    let onDuplicate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.tint)
                .font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(profileName) is a built-in profile")
                    .font(.callout.weight(.medium))
                Text("Duplicate it to make your own version you can edit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onDuplicate) {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
    }
}
