import Foundation
import Combine
import UserNotifications
import OSLog

/// Thin wrapper around `UNUserNotificationCenter` for the safe-listening
/// threshold notifications (spec §5.4). User-facing surfaces use one of the
/// `send*` methods; permission state is tracked internally so callers don't
/// need to gate.
@MainActor
final class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var isAuthorized: Bool { authorizationStatus == .authorized || authorizationStatus == .provisional }

    private let log = Logger(subsystem: "com.shawnbrown.SherlockEQ", category: "Notifications")
    private let delegateAdapter = ForegroundDeliveryAdapter()

    private override init() {
        super.init()
        // macOS only displays banners while the app is in the background unless
        // the notification-center delegate explicitly opts in. We always want
        // safe-listening warnings to surface even when SherlockEQ is foreground.
        UNUserNotificationCenter.current().delegate = delegateAdapter
        Task { await refreshAuthorizationStatus() }
    }

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Request banner + sound authorization. Idempotent — macOS only prompts
    /// the user the first time per bundle ID.
    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            log.info("Notification authorization request → \(granted ? "granted" : "denied")")
        } catch {
            log.error("Authorization request failed: \(error.localizedDescription, privacy: .public)")
        }
        await refreshAuthorizationStatus()
    }

    /// Adapter that lets notifications show as banners while SherlockEQ is the
    /// frontmost app. Has to be NSObject + nonisolated to satisfy the delegate
    /// protocol; lives separate from the main MainActor type to avoid friction.
    private final class ForegroundDeliveryAdapter: NSObject, UNUserNotificationCenterDelegate {
        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .sound, .list])
        }
    }

    /// Send a user-visible notification. No-ops when notifications aren't
    /// authorized. Fire-and-forget for callers (sync signature preserved).
    ///
    /// The authorization gate is checked *after* an on-demand refresh when the
    /// status is still `.notDetermined`: a dose crossing can fire moments after
    /// launch, before the async `refreshAuthorizationStatus()` kicked off in
    /// `init` has resolved. Gating on the stale `.notDetermined` there would
    /// silently drop the warning — and because the safe-listening crossing flag
    /// is one-shot per day, that warning would never re-fire. Refreshing first
    /// ensures a genuinely-authorized user still gets it.
    func send(title: String, body: String, identifier: String = UUID().uuidString) {
        Task { @MainActor in
            if authorizationStatus == .notDetermined {
                await refreshAuthorizationStatus()
            }
            guard isAuthorized else {
                log.info("Notification suppressed — not authorized (status \(self.authorizationStatus.rawValue))")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { [log] error in
                if let error {
                    log.error("Notification post failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
