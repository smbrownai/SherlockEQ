import Foundation
import Combine
import AppKit

/// The single entry point for opening help from anywhere in the app:
///
///     HelpCenter.shared.open(topic: .audiogramProfiles)
///
/// It owns the content library and the in-window navigation state
/// (current article + back/forward history) so the help window stays a
/// thin view over it. Window *presentation* is delegated back to the
/// `AppDelegate` via the `onShow` hook — `HelpCenter` never touches
/// NSWindow itself, which keeps window-lifecycle code in one place and
/// lets contextual `?` buttons stay decoupled from the delegate.
@MainActor
final class HelpCenter: ObservableObject {

    static let shared = HelpCenter()

    let library = HelpLibrary()

    /// Slug of the article currently shown. Drives `HelpWindowView`.
    @Published private(set) var currentSlug: String

    /// Search text bound to the window's search field. Kept here (not in
    /// the view's `@State`) so a search can survive a window close/reopen.
    @Published var searchText: String = ""

    private var backStack: [String] = []
    private var forwardStack: [String] = []

    /// Set by `AppDelegate` at launch. Brings the (lazily created) help
    /// window forward. `HelpCenter` calls it after every `open(...)`.
    var onShow: (() -> Void)?

    private init() {
        currentSlug = HelpTopic.home.slug
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    var currentDocument: HelpDocument? { library.document(for: currentSlug) }

    // MARK: - Public open API

    /// Open the help window and navigate to a topic.
    func open(topic: HelpTopic) {
        navigate(to: topic.slug)
        onShow?()
    }

    /// Open the help window at whatever article was last shown.
    func open() {
        onShow?()
    }

    /// Open by slug — used by internal markdown links (`help:slug`).
    func open(slug: String) {
        navigate(to: slug)
        onShow?()
    }

    // MARK: - Navigation

    /// Navigate to a slug, pushing the prior article onto the back stack.
    /// A no-op if the slug is unknown or already current.
    func navigate(to slug: String) {
        guard library.document(for: slug) != nil else { return }
        guard slug != currentSlug else { return }
        backStack.append(currentSlug)
        forwardStack.removeAll()
        currentSlug = slug
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentSlug)
        currentSlug = previous
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentSlug)
        currentSlug = next
    }

    // MARK: - Link handling

    /// Route a URL tapped inside a help article. Internal links use the
    /// `help:` scheme (`help:per-ear-eq`); everything else is treated as
    /// external and opened in the user's browser. Returns the SwiftUI
    /// `OpenURLAction.Result` so the renderer's environment handler can
    /// tell SwiftUI we consumed internal links ourselves.
    enum LinkOutcome { case handledInternally, openExternally(URL) }

    func handle(url: URL) -> LinkOutcome {
        if url.scheme == "help" {
            // `help:slug` parses with the slug as the path (opaque) — accept
            // both `help:slug` and `help://slug` forms.
            let slug = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let resolved = slug.isEmpty ? (url.absoluteString.replacingOccurrences(of: "help:", with: "")) : slug
            navigate(to: resolved)
            return .handledInternally
        }
        return .openExternally(url)
    }

    // MARK: - Version

    /// "1.2.3 (45)" — surfaced in the help window footer so users know
    /// which build the documentation corresponds to.
    var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}
