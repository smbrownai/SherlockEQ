import SwiftUI

/// Row in the profiles list. The row's **selection highlight** means
/// "currently being edited"; a single green **Active** pill means "currently
/// processing audio". Those are the only two status signals — the old
/// competing green dot + footer are gone, and the built-in marker is a quiet
/// trailing star.
struct ProfileListItem: View {
    let profile: HearingProfile
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: profile.symbol)
                .frame(width: 18)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .lineLimit(1)
                    if profile.isBuiltIn {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .help("Built-in preset")
                    }
                }
                if let description = profile.presetDescription, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let uid = profile.linkedDeviceUID, !uid.isEmpty {
                    Text(uid)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if isActive {
                Text("Active")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.green))
                    .help("Currently processing audio")
                    .accessibilityLabel("Active — currently processing audio")
            }
        }
        .padding(.vertical, 2)
    }
}
