import SwiftUI

/// Banner shown above the editor when the active profile is one of the
/// shipped factory listening presets. Factory presets are editable in
/// place — this isn't a lock — so it offers two recovery paths: revert this
/// preset to its shipped values ("Reset to Factory Default"), or branch a
/// separate editable copy ("Duplicate"). Reset is disabled when the preset
/// already matches its factory definition.
struct FactoryPresetBanner: View {
    let profileName: String
    let canReset: Bool
    let onReset: () -> Void
    let onDuplicate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "star.fill")
                .foregroundStyle(.tint)
                .font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(profileName) is a built-in preset")
                    .font(.callout.weight(.medium))
                Text("Your changes are saved to it. Reset it to the original anytime, or duplicate it to keep a separate copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onReset) {
                Label("Reset to Default", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canReset)
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
