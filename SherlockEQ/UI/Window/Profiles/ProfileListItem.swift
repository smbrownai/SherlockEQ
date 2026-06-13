import SwiftUI

/// Row in the profiles list. Shows symbol, name, and a subtle "active" dot
/// when this profile is the currently-active one in `AudioState`.
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
                            .foregroundStyle(.tint)
                            .help("Built-in preset")
                    }
                }
                if let description = profile.presetDescription, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                // Tag pills are intentionally omitted here — they ate too much
                // vertical room in the narrow sidebar. They still appear under
                // the description on the profile detail screen.
                if let uid = profile.linkedDeviceUID, !uid.isEmpty {
                    Text(uid)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if isActive {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                    .help("Active profile")
            }
        }
        .padding(.vertical, 2)
    }
}
