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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .lineLimit(1)
                    if profile.isBuiltIn {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .help("Built-in — duplicate to customize")
                    }
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
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                    .help("Active profile")
            }
        }
        .padding(.vertical, 2)
    }
}
