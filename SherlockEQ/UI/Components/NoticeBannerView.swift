import AppKit
import SwiftUI

/// Lightweight, dismissible status banner shown at the top of the main
/// window for save failures, permission revocations, and other
/// transient surfaces. Fed by `AudioState.noticeCenter.userVisibleNotice`.
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
///
/// VoiceOver: posts an `announcementRequested` notification on appear
/// so VO users hear errors / warnings without needing to navigate to
/// the banner first. Without it the banner is a silent re-render
/// from VO's perspective; with it the message reads out at the
/// configured priority (high for errors, default for warnings).
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
                    // 28×28 hit area — Apple recommends 44pt minimum
                    // but a banner-row dismiss control on macOS has
                    // less room; 28pt is the smallest that still beats
                    // the 12pt bare-image target previously here.
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notice")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        // Severity-tinted Liquid Glass on Tahoe (the banner floats over
        // content, which is exactly the layer glass is for); the pre-26
        // tinted fill + stroke on Sonoma. Severity keeps its non-color
        // signal either way (triangle vs octagon icon).
        .glassChipSurface(
            tint: tint.opacity(0.3),
            cornerRadius: 8,
            fallbackFill: tint.opacity(0.12),
            fallbackStroke: tint.opacity(0.45)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
        .onAppear { announceToVoiceOver() }
        .onChange(of: notice.id) { _, _ in announceToVoiceOver() }
    }

    private func announceToVoiceOver() {
        let priority: NSAccessibilityPriorityLevel = notice.severity == .error ? .high : .medium
        NSAccessibility.post(
            element: NSApp.mainWindow as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: notice.message,
                .priority: priority.rawValue,
            ]
        )
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
