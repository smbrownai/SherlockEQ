import SwiftUI

/// Lightweight, dismissible status banner shown at the top of the main
/// window for save failures, permission revocations, and other
/// transient surfaces. Fed by `AudioState.userVisibleNotice`.
///
/// Warnings auto-dismiss after their `autoDismissAfter` duration so
/// the banner doesn't permanently take a row of window real estate
/// for something already past. Errors stay until the user taps the
/// dismiss control — they usually represent persistent state
/// (revoked permission, missing folder, save still failing) where
/// timeout would be misleading.
struct TransientNotice: Identifiable, Equatable {
    enum Severity: Equatable {
        case warning
        case error
    }

    let id: UUID
    let severity: Severity
    let message: String
    /// Nil = no auto-dismiss. Defaults: 6 s for warnings, nil for errors.
    let autoDismissAfter: TimeInterval?

    init(
        severity: Severity,
        message: String,
        autoDismissAfter: TimeInterval? = nil
    ) {
        self.id = UUID()
        self.severity = severity
        self.message = message
        self.autoDismissAfter = autoDismissAfter
            ?? (severity == .warning ? 6 : nil)
    }
}

/// Self-contained banner row. Caller positions it (typically at the
/// top of a window's detail area); component handles its own padding,
/// background, icon, and dismiss button.
struct NoticeBannerView: View {
    let notice: TransientNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.body.weight(.semibold))
            Text(notice.message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notice")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(0.45))
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    private var icon: String {
        switch notice.severity {
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "exclamationmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch notice.severity {
        case .warning: return .orange
        case .error:   return .red
        }
    }
}
