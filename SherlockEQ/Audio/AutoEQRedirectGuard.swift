import Foundation

/// Redirect policy for AutoEQ network fetches (audit N-3).
///
/// `AutoEQRemoteService` fetches from GitHub's raw-content host. Left to the
/// default `URLSession` behaviour, an HTTP 3xx from the origin — a MITM, or a
/// compromised / misconfigured endpoint — would be followed automatically to
/// *any* host, and the body fetched from there would be parsed as an AutoEQ
/// index or profile (bounded to 8 MB, but still attacker-chosen content).
///
/// This task delegate pins redirects to GitHub's content family over HTTPS. A
/// redirect that leaves it is cancelled by handing the completion handler
/// `nil`; the task then surfaces the 3xx response itself, which
/// `fetchString` maps to `AutoEQFetchError.other("HTTP 3xx")` — so an off-host
/// redirect fails the fetch instead of silently sourcing content elsewhere.
/// Same-family redirects still follow, so GitHub's own CDN indirection
/// (e.g. `objects.githubusercontent.com`) keeps working.
/// `@unchecked Sendable`: the guard holds no stored state — it's passed
/// per-task to `session.data(from:delegate:)` from the `@MainActor` service and
/// invoked on the URL session's delegate queue, so it crosses isolation
/// boundaries, but there is nothing mutable to race on.
final class AutoEQRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    /// A redirect target is allowed only if it stays on HTTPS and within
    /// GitHub's `*.githubusercontent.com` content family. The leading dot in
    /// the suffix match defeats look-alikes such as `evilgithubusercontent.com`
    /// (no dot boundary → rejected).
    static func isAllowedRedirect(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "githubusercontent.com" || host.hasSuffix(".githubusercontent.com")
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.isAllowedRedirect(request.url) ? request : nil)
    }
}
