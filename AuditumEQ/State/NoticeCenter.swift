import Foundation
import Combine
import UserNotifications

/// User-visible banner state — surfaces save failures, permission
/// revocations, the notifications-denied-while-dosing warning, and
/// any other transient condition the user can act on. Rendered by
/// `NoticeBannerView` (mounted in `MainWindowView`) when
/// `userVisibleNotice != nil`.
///
/// Extracted from `AudioState` so view code that only cares about
/// banner state doesn't pull in the whole audio pipeline as a
/// dependency, and so any future code path that wants to surface a
/// notice (Settings, an import flow, etc.) has a clear destination.
@MainActor
final class NoticeCenter: ObservableObject {

    /// Currently-displayed notice, or nil. Set via `showNotice(_:)` so
    /// warnings get their auto-dismiss; errors stay until the user
    /// taps the close control on the banner.
    @Published private(set) var userVisibleNotice: TransientNotice?

    /// Pending auto-dismiss timer for `userVisibleNotice`. Cancelled
    /// whenever a new notice is shown or the user dismisses manually,
    /// so a stale fire-after can't yank a fresher notice off-screen.
    private var dismissTask: Task<Void, Never>?

    /// Combine sinks for each error source. Stored so we can rebind
    /// later if a source reference changes (currently only at init,
    /// but keeping these as AnyCancellable makes that trivial to
    /// add).
    private var profileLastErrorSubscription: AnyCancellable?
    private var tapStateSubscription: AnyCancellable?
    private var audioLastErrorSubscription: AnyCancellable?

    /// One-shot guard so the startup "notifications were denied"
    /// warning doesn't fire repeatedly if `warnIfNotificationsDenied`
    /// gets called more than once per session.
    private var warnedAboutDeniedNotificationsAtStartup = false

    /// Bind to a profile store so persistence errors automatically
    /// surface in the banner. Idempotent — calling twice rebinds; the
    /// previous subscription is cancelled. `ProfileStore.lastError`
    /// is set by the `tracking` wrapper around every throwing op
    /// (save / delete / import / export / relocate / loadAll), so
    /// every persistence failure shows up here without each call
    /// site needing to plumb the error itself.
    func bind(to profileStore: ProfileStore) {
        profileLastErrorSubscription = profileStore.$lastError
            .compactMap { $0 }
            .sink { [weak self] message in
                Task { @MainActor in
                    self?.showNotice(
                        TransientNotice(severity: .error, message: message)
                    )
                }
            }
    }

    /// Bind to the CATap engine so a `.failed(msg)` or
    /// `.permissionDenied` transition surfaces as an error banner.
    /// Permission denial is the single biggest gotcha — without it,
    /// a first-launch user who declines Screen Recording sees the
    /// app's normal UI with no indication that nothing's working.
    /// `removeDuplicates` so a `.starting → .running` arc doesn't
    /// re-fire any notice; we only react to states the user needs
    /// to know about.
    func bindTapState(_ tap: CATapEngine) {
        tapStateSubscription = tap.$state
            .removeDuplicates()
            .sink { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .permissionDenied:
                        self?.showNotice(TransientNotice(
                            severity: .error,
                            message: "Audio capture needs Microphone permission. Open System Settings → Privacy & Security → Microphone to enable AuditumEQ."
                        ))
                    case .failed(let msg):
                        self?.showNotice(TransientNotice(
                            severity: .error,
                            message: msg
                        ))
                    case .idle, .awaitingPermission, .starting, .running:
                        break
                    }
                }
            }
    }

    /// Bind to the AVAudioEngine wrapper so its `lastError` shows up
    /// in the banner. Already auto-clears on successful start, so
    /// the banner reflects current state without manual dismissal.
    func bindAudioLastError(_ audio: AuditumEQAudioEngine) {
        audioLastErrorSubscription = audio.$lastError
            .compactMap { $0 }
            .sink { [weak self] message in
                Task { @MainActor in
                    self?.showNotice(TransientNotice(
                        severity: .error,
                        message: "Audio engine: \(message)"
                    ))
                }
            }
    }

    /// One-shot per-session warning if notification authorization is
    /// denied or undetermined. Called from AppDelegate after the
    /// initial requestAuthorization completes — so a user who
    /// declined notifications on first launch learns immediately that
    /// they've lost safe-listening alerts, instead of waiting until
    /// dose first reaches amber (the other path
    /// `AudioState.checkNotificationsDeniedAtAmberDose` covers).
    func warnIfNotificationsDenied(status: UNAuthorizationStatus) {
        guard !warnedAboutDeniedNotificationsAtStartup else { return }
        guard status == .denied || status == .notDetermined else { return }
        warnedAboutDeniedNotificationsAtStartup = true
        showNotice(TransientNotice(
            severity: .warning,
            message: "Notifications are off — you won't get safe-listening alerts. Enable them in System Settings → Notifications → AuditumEQ.",
            autoDismissAfter: 12
        ))
    }

    /// Show a transient banner notice. Errors stay until the user
    /// dismisses; warnings auto-dismiss per the notice's
    /// `autoDismissAfter`. Replacing the current notice cancels any
    /// pending auto-dismiss for the previous one.
    func showNotice(_ notice: TransientNotice) {
        dismissTask?.cancel()
        userVisibleNotice = notice
        guard let delay = notice.autoDismissAfter else { return }
        let noticeID = notice.id
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Only dismiss if the same notice is still up — a newer
            // one would have replaced it via showNotice's cancel-
            // then-set, but defensive belt-and-braces.
            if self?.userVisibleNotice?.id == noticeID {
                self?.userVisibleNotice = nil
            }
        }
    }

    /// User-initiated dismiss from the banner's close control.
    func dismissNotice() {
        dismissTask?.cancel()
        userVisibleNotice = nil
    }
}
