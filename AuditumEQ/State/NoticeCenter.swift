import Foundation
import Combine

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

    /// Combine sink that watches `ProfileStore.lastError` and turns
    /// each non-nil value into an error banner. Stored so we can
    /// rebind when the store reference changes (currently only at
    /// init time, but keeping it AnyCancellable here makes that
    /// trivial to add).
    private var lastErrorSubscription: AnyCancellable?

    /// Bind to a profile store so persistence errors automatically
    /// surface in the banner. Idempotent — calling twice rebinds; the
    /// previous subscription is cancelled. `ProfileStore.lastError`
    /// is set by the `tracking` wrapper around every throwing op
    /// (save / delete / import / export / relocate / loadAll), so
    /// every persistence failure shows up here without each call
    /// site needing to plumb the error itself.
    func bind(to profileStore: ProfileStore) {
        lastErrorSubscription = profileStore.$lastError
            .compactMap { $0 }
            .sink { [weak self] message in
                Task { @MainActor in
                    self?.showNotice(
                        TransientNotice(severity: .error, message: message)
                    )
                }
            }
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
