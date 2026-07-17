import Foundation
import Combine
import OSLog

/// On-demand fetcher for the AutoEQ catalog. The service:
///
///   * Owns the on-disk cache root under `Application Support/SherlockEQ`.
///   * Publishes the loaded index (so `AutoEQSearchView` can bind to it).
///   * Performs index + profile fetches over plain `URLSession`.
///   * Surfaces failures as a typed `AutoEQFetchError` for the UI.
///
/// The service does NOT decide *when* to apply a profile — that's the
/// saved-profiles store + the hearing profile editor. It only fetches,
/// parses, and caches.
@MainActor
final class AutoEQRemoteService: ObservableObject {

    // MARK: - Errors

    /// User-facing categorisation of fetch failures. Display copy is
    /// derived in the view layer so the same error can show as a banner
    /// or an inline row label depending on context.
    /// Upper bound for any single fetched body — see fetchString (SEC-02).
    static let maxResponseBytes = 8 * 1024 * 1024

    enum AutoEQFetchError: Error, Equatable {
        case offline           // URL host unreachable
        case rateLimited       // GitHub 403, surface backoff message
        case notFound          // 404
        case parseFailure      // body returned but didn't parse
        case other(String)     // anything else; carries OS error description
    }

    // MARK: - Published surface

    /// Loaded index — nil until the first fetch (or cache load) completes.
    @Published private(set) var index: AutoEQIndex?

    /// Whether the service is currently fetching the index. Used by the
    /// search view to show a "Loading headphone library…" hint.
    @Published private(set) var isLoadingIndex = false

    /// Last index-fetch error, if any. Cleared on the next successful fetch.
    @Published private(set) var indexError: AutoEQFetchError?

    // MARK: - Config

    private let session: URLSession
    private let log = Logger(subsystem: "com.shawnbrown.SherlockEQ", category: "AutoEQRemoteService")

    /// AutoEQ's catalog is published from a single repo. The path inside
    /// the repo is `results/README.md` for the index and
    /// `results/{source}/{type}/{name}/ParametricEQ.txt` for each profile.
    private static let indexURL = URL(
        string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/README.md"
    )!

    private static let profileBaseURL = URL(
        string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"
    )!

    /// Per-spec: refresh the index in the background once a week.
    static let indexRefreshInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Per-spec: after a 403 rate-limit, don't retry for at least 5 minutes.
    static let rateLimitBackoff: TimeInterval = 5 * 60
    private var nextRateLimitRetry: Date?

    init(session: URLSession = .shared) {
        self.session = session
        // Loading from disk is cheap; do it eagerly so the search view
        // can render results on first appearance without waiting for a
        // network round-trip.
        loadIndexFromDiskIfPresent()
    }

    // MARK: - Index lifecycle

    /// Load the cached index from disk if present. Silent no-op on
    /// failure — the service stays in the no-index state and the
    /// first fetch will populate it.
    private func loadIndexFromDiskIfPresent() {
        let url = Self.indexCacheURL
        guard let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder.autoEQ.decode(AutoEQIndex.self, from: data) else {
            return
        }
        self.index = cached
        log.info("Loaded \(cached.entries.count) AutoEQ entries from cache (age \(Int(Date().timeIntervalSince(cached.fetchedAt))) s)")
    }

    /// Returns true when the cached index is missing or older than the
    /// 7-day refresh window. Caller decides whether to surface a
    /// loading hint or refresh silently in the background.
    var indexNeedsRefresh: Bool {
        guard let index else { return true }
        return Date().timeIntervalSince(index.fetchedAt) > Self.indexRefreshInterval
    }

    /// Fetch the index from the network and persist it. Safe to call
    /// repeatedly — early-bails if a fetch is already in flight.
    func refreshIndex(forceWhenLoading: Bool = false) async {
        if isLoadingIndex && !forceWhenLoading { return }
        isLoadingIndex = true
        defer { isLoadingIndex = false }

        do {
            let text = try await fetchString(from: Self.indexURL)
            let entries = AutoEQIndexParser.parse(text)
            guard !entries.isEmpty else {
                // Per spec: zero-entry parse means upstream regression
                // or HTML error page. Fall back to cached silently.
                log.error("Index fetch parsed 0 entries — falling back to cached version")
                indexError = .parseFailure
                return
            }
            let bundle = AutoEQIndex(entries: entries, fetchedAt: Date())
            try persistIndex(bundle)
            self.index = bundle
            self.indexError = nil
            log.info("Refreshed AutoEQ index — \(entries.count) entries")
        } catch let error as AutoEQFetchError {
            indexError = error
            log.error("Index fetch failed: \(String(describing: error), privacy: .public)")
        } catch {
            indexError = .other(error.localizedDescription)
            log.error("Index fetch failed (unexpected): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistIndex(_ bundle: AutoEQIndex) throws {
        let url = Self.indexCacheURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder.autoEQ.encode(bundle)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Profile fetch

    /// Fetch and parse a single ParametricEQ.txt. On success, persist
    /// the structured profile to the cache directory and return it.
    /// Throws an `AutoEQFetchError` on any failure — including parse
    /// failures, which the caller may want to surface as inline row
    /// state.
    func fetchProfile(for entry: AutoEQIndexEntry) async throws -> AutoEQRemoteProfile {
        if let cached = loadCachedProfile(for: entry) {
            return cached
        }
        if let next = nextRateLimitRetry, Date() < next {
            throw AutoEQFetchError.rateLimited
        }

        let url = Self.profileURL(for: entry)
        let text: String
        do {
            text = try await fetchString(from: url)
        } catch let error as AutoEQFetchError {
            if case .rateLimited = error {
                nextRateLimitRetry = Date().addingTimeInterval(Self.rateLimitBackoff)
            }
            throw error
        }

        guard let profile = AutoEQRemoteParser.parse(text, entry: entry) else {
            throw AutoEQFetchError.parseFailure
        }

        do {
            try persistProfile(profile)
        } catch {
            log.error("Failed to persist profile cache for \(entry.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // Persist failure is non-fatal — return the profile so the
            // caller can still apply it. Next launch we'll re-fetch.
        }
        return profile
    }

    /// Load a previously-fetched profile from cache. Returns nil when
    /// the file is missing or fails to decode (shape change, etc.).
    func loadCachedProfile(for entry: AutoEQIndexEntry) -> AutoEQRemoteProfile? {
        let url = Self.profileCacheURL(for: entry)
        guard let data = try? Data(contentsOf: url),
              let profile = try? JSONDecoder.autoEQ.decode(AutoEQRemoteProfile.self, from: data) else {
            return nil
        }
        return profile
    }

    /// Delete a cached profile from disk. Best-effort — silent if the
    /// file is already gone. Pairs with the saved-list Delete action.
    func deleteCachedProfile(for entry: AutoEQIndexEntry) {
        let url = Self.profileCacheURL(for: entry)
        try? FileManager.default.removeItem(at: url)
    }

    private func persistProfile(_ profile: AutoEQRemoteProfile) throws {
        let url = Self.profileCacheURL(source: profile.source, type: profile.type, name: profile.headphoneName)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder.autoEQ.encode(profile)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - URL building

    /// Build the raw.githubusercontent.com URL for a profile's
    /// ParametricEQ.txt. Each path component is percent-encoded
    /// individually so spaces and parentheses in headphone names
    /// don't break the request, but the `/` separators stay literal.
    ///
    /// AutoEq names the file `<HeadphoneName> ParametricEQ.txt` inside
    /// each headphone folder, not just `ParametricEQ.txt` — the spec
    /// doc undersells this. Verified against the live repo:
    ///
    ///   /results/oratory1990/over-ear/Sennheiser HD 650/Sennheiser HD 650 ParametricEQ.txt
    ///
    /// We use the index entry's `name` as the leaf prefix. If a future
    /// AutoEq reorganisation breaks this assumption, swap in a probe
    /// of the headphone folder's `README.md` to discover the actual
    /// filename — but for now every entry in the catalog follows the
    /// rule, and the 404 fallback path surfaces a clean inline error
    /// if any single profile diverges.
    static func profileURL(for entry: AutoEQIndexEntry) -> URL {
        let encodedComponents = entry.path
            .split(separator: "/")
            .map { component -> String in
                let raw = String(component)
                return raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
            }
        let joinedDirs = encodedComponents.joined(separator: "/")
        let encodedLeaf: String = {
            let raw = "\(entry.name) ParametricEQ.txt"
            return raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
        }()
        // Build via string concatenation so the per-component percent
        // encoding we already did doesn't get re-encoded by
        // appendingPathComponent.
        let combined = profileBaseURL.absoluteString + joinedDirs + "/" + encodedLeaf
        return URL(string: combined)
            ?? profileBaseURL
                .appendingPathComponent(joinedDirs, isDirectory: true)
                .appendingPathComponent("\(entry.name) ParametricEQ.txt")
    }

    // MARK: - Networking

    /// Generic GET → String helper. Maps URLSession failures to
    /// `AutoEQFetchError`. The `Data → String` decode is utf-8 only;
    /// AutoEQ's files are ASCII so no need for fallback encodings.
    private func fetchString(from url: URL) async throws -> String {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<300:
                    break
                case 403:
                    throw AutoEQFetchError.rateLimited
                case 404:
                    throw AutoEQFetchError.notFound
                default:
                    throw AutoEQFetchError.other("HTTP \(http.statusCode)")
                }
            }
            // Defense-in-depth (audit SEC-02): never hand an absurd body to
            // the decoder/parsers/cache. AutoEQ payloads are a ~1 MB index
            // and KB-sized filter files; a compromised origin or MITM
            // shouldn't get to feed us hundreds of MB. `session.data` has
            // already buffered the download by this point, so this bounds
            // what we PROCESS, not transfer — a mid-stream abort would need
            // a delegate-based reader, unwarranted for a DoS-only threat.
            guard data.count <= Self.maxResponseBytes else {
                throw AutoEQFetchError.other("Response too large (\(data.count) bytes)")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw AutoEQFetchError.parseFailure
            }
            return text
        } catch let error as AutoEQFetchError {
            throw error
        } catch {
            // URLError → offline mapping. The most common code we'll
            // see in practice is `.notConnectedToInternet`, but several
            // adjacent codes (timeout, host unreachable, DNS failure)
            // should also surface as "offline" to the user since the
            // remedy is the same.
            if let urlError = error as? URLError {
                switch urlError.code {
                case .notConnectedToInternet,
                     .networkConnectionLost,
                     .timedOut,
                     .cannotFindHost,
                     .cannotConnectToHost,
                     .dnsLookupFailed:
                    throw AutoEQFetchError.offline
                default:
                    throw AutoEQFetchError.other(urlError.localizedDescription)
                }
            }
            throw AutoEQFetchError.other(error.localizedDescription)
        }
    }

    // MARK: - On-disk locations

    /// `~/Library/Application Support/SherlockEQ`. Same root the rest of
    /// the app uses (profiles JSON, etc.).
    static var supportDirectory: URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SherlockEQ", isDirectory: true)
    }

    static var indexCacheURL: URL {
        supportDirectory.appendingPathComponent("autoeq_index.json", isDirectory: false)
    }

    static var profileCacheRoot: URL {
        supportDirectory.appendingPathComponent("autoeq_profiles", isDirectory: true)
    }

    static func profileCacheURL(for entry: AutoEQIndexEntry) -> URL {
        profileCacheURL(source: entry.source, type: entry.type, name: entry.name)
    }

    private static func profileCacheURL(source: String, type: String, name: String) -> URL {
        profileCacheRoot
            .appendingPathComponent(safePathComponent(source), isDirectory: true)
            .appendingPathComponent(safePathComponent(type), isDirectory: true)
            .appendingPathComponent("\(safePathComponent(name)).json", isDirectory: false)
    }

    /// Sanitize an untrusted catalog string into a single safe path component.
    /// The headphone name / source / type are parsed from a remote markdown
    /// index, so a crafted or MITM'd entry like `../../../../tmp/evil` (or a
    /// `name` containing `/`) would otherwise escape the cache root when used
    /// to build a file path — `appendingPathComponent` happily interprets
    /// embedded separators and `..`. We strip path-meaningful and illegal
    /// characters and neutralize leading dots so every component stays inside
    /// `autoeq_profiles/`. Applied on both the write (persist) and read
    /// (load/delete) paths via this one chokepoint, so they map identically.
    static func safePathComponent(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "\\", with: "_")
        s = s.replacingOccurrences(of: ":", with: "_")   // HFS path separator
        s = s.replacingOccurrences(of: "\u{0}", with: "")
        // Drop leading dots so "..", "." and hidden names can't traverse/hide.
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "_" : s
    }
}

// MARK: - Coder helpers

private extension JSONEncoder {
    /// One configured encoder so all AutoEQ JSON files round-trip with
    /// the same date strategy and key conventions. ISO 8601 keeps the
    /// files human-debuggable without a custom format string.
    static var autoEQ: JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }
}

private extension JSONDecoder {
    static var autoEQ: JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }
}
