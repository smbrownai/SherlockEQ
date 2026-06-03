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

    private let log = Logger(subsystem: "com.shawnbrown.AuditumEQ", category: "Notifications")
    private let delegateAdapter = ForegroundDeliveryAdapter()

    private override init() {
        super.init()
        // macOS only displays banners while the app is in the background unless
        // the notification-center delegate explicitly opts in. We always want
        // safe-listening warnings to surface even when AuditumEQ is foreground.
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

    /// Adapter that lets notifications show as banners while AuditumEQ is the
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

    /// Send a user-visible notification immediately. Silently no-ops when
    /// authorization hasn't been granted.
    func send(title: String, body: String, identifier: String = UUID().uuidString) {
        guard isAuthorized else { return }
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
