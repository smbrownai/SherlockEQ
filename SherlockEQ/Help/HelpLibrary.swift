import Foundation
import OSLog

/// Loads every bundled help article once, indexes them by slug, and
/// answers search queries. Pure data + logic, no UI and no navigation
/// state — `HelpCenter` owns routing, this owns content.
///
/// Articles live as flat `.md` files in the app bundle's Resources
/// (the Xcode synchronized `Documentation/` folder is copied there with
/// its directory structure flattened, so `forResource:` lookup by the
/// bare slug works). Loading is lazy: the first property access triggers
/// a one-time scan, so a session that never opens Help pays nothing.
@MainActor
final class HelpLibrary {

    private static let log = Logger(subsystem: "com.shawnbrown.SherlockEQ", category: "Help")

    private(set) lazy var documents: [String: HelpDocument] = loadAll()

    /// Ordered sidebar / menu structure. Sections render top-to-bottom;
    /// topics within a section render in the order listed here. This is
    /// the canonical ordering — front-matter `category` is informational,
    /// but the outline below drives what the user actually sees so we get
    /// deterministic grouping without depending on file load order.
    static let outline: [HelpSection] = [
        HelpSection(title: "Overview", topics: [
            .home, .gettingStarted, .featureGuide,
        ]),
        HelpSection(title: "Core EQ", topics: [
            .understandingEQ, .gainVolume, .balance, .simpleEQ, .parametricEQ,
        ]),
        HelpSection(title: "Hearing-Aware Features", topics: [
            .perEarEQ, .audiogramProfiles, .tinnitusToneMatching, .headphoneCorrection,
        ]),
        HelpSection(title: "Metering & Visualization", topics: [
            .vuMeters, .spectrumVisualization,
        ]),
        HelpSection(title: "Surfaces & Organization", topics: [
            .analogControlUnit, .outputDevices, .profiles,
        ]),
        HelpSection(title: "Responsibility & Data", topics: [
            .safetyLimits, .privacy,
        ]),
        HelpSection(title: "Reference", topics: [
            .troubleshooting, .keyboardShortcuts, .commandLineTool, .releaseNotes, .references,
        ]),
    ]

    func document(for slug: String) -> HelpDocument? { documents[slug] }
    func document(for topic: HelpTopic) -> HelpDocument? { documents[topic.slug] }

    /// Resolve a slug to its display title without forcing a full render.
    func title(for slug: String) -> String {
        documents[slug]?.title
            ?? HelpTopic(slug: slug).map { $0.slug.replacingOccurrences(of: "-", with: " ").capitalized }
            ?? slug
    }

    // MARK: - Search

    /// Rank documents against a free-text query. Title and keyword hits
    /// outweigh body hits; an exact title match floats to the top. Query
    /// terms are expanded with a small synonym table so "ringing" finds
    /// the tinnitus article and "presets" finds profiles.
    func search(_ rawQuery: String) -> [HelpSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }

        // Each query word becomes a *group*: the word plus its synonyms.
        // A group is satisfied when ANY member matches (so "presets" finds
        // the article that says "profiles"); every group must be satisfied
        // (AND across words) so multi-word queries stay precise.
        let groups = Self.synonymGroups(for: query.split(whereSeparator: { $0 == " " }).map(String.init))
        guard !groups.isEmpty else { return [] }
        let allTerms = groups.flatMap { $0 }

        var results: [HelpSearchResult] = []
        for doc in documents.values {
            var score = 0
            var matchedAll = true
            for group in groups {
                var groupScore = 0
                for term in group {
                    var termScore = 0
                    if doc.title.lowercased() == term { termScore += 100 }
                    if doc.title.lowercased().contains(term) { termScore += 40 }
                    if doc.metadata.keywords.contains(where: { $0.lowercased().contains(term) }) { termScore += 25 }
                    if doc.metadata.summary.lowercased().contains(term) { termScore += 12 }
                    let bodyHits = doc.searchHaystack.components(separatedBy: term).count - 1
                    if bodyHits > 0 { termScore += min(bodyHits, 8) }
                    groupScore = max(groupScore, termScore)
                }
                if groupScore == 0 { matchedAll = false; break }
                score += groupScore
            }
            guard matchedAll, score > 0 else { continue }
            results.append(HelpSearchResult(
                slug: doc.slug,
                title: doc.title,
                summary: doc.metadata.summary,
                snippet: Self.snippet(in: doc, terms: allTerms),
                score: score
            ))
        }
        return results.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.title < $1.title
        }
    }

    /// Synonym expansion: each query term also matches the canonical term
    /// it's a synonym for, so the user's everyday word finds the article
    /// that uses the technical word (and vice versa).
    private static let synonyms: [String: [String]] = [
        "volume": ["gain"], "gain": ["volume"],
        "loud": ["gain", "loudness"], "loudness": ["gain"],
        "left": ["balance"], "right": ["balance"],
        "pan": ["balance"],
        "hearing": ["audiogram"], "test": ["audiogram"], "threshold": ["audiogram"],
        "ringing": ["tinnitus"], "tone": ["tinnitus"],
        "headphone": ["autoeq", "correction"], "headphones": ["autoeq", "correction"],
        "earphone": ["autoeq"], "iem": ["autoeq"],
        "distortion": ["clipping"], "distorted": ["clipping"], "clip": ["clipping"],
        "meter": ["vu"], "meters": ["vu"], "level": ["vu"],
        "preset": ["profile"], "presets": ["profiles"],
        "delay": ["latency"], "lag": ["latency"],
        "bluetooth": ["latency", "output"],
        "notch": ["tinnitus"],
        "spectrum": ["visualization"], "analyzer": ["spectrum"],
        "treble": ["eq"], "bass": ["eq"], "mid": ["eq"], "mids": ["eq"],
        "safe": ["safety"], "dose": ["safety"], "niosh": ["safety"],
    ]

    private static func synonymGroups(for terms: [String]) -> [[String]] {
        var groups: [[String]] = []
        for term in terms where !term.isEmpty {
            var group = [term]
            for syn in synonyms[term] ?? [] where !group.contains(syn) {
                group.append(syn)
            }
            groups.append(group)
        }
        return groups
    }

    /// A short body excerpt around the first matching term, for the
    /// results list. Falls back to the summary when no body match exists.
    private static func snippet(in doc: HelpDocument, terms: [String]) -> String {
        let lower = doc.searchHaystack
        for term in terms {
            if let r = lower.range(of: term) {
                let start = lower.index(r.lowerBound, offsetBy: -40, limitedBy: lower.startIndex) ?? lower.startIndex
                let end = lower.index(r.upperBound, offsetBy: 80, limitedBy: lower.endIndex) ?? lower.endIndex
                var excerpt = String(lower[start..<end])
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                if start != lower.startIndex { excerpt = "…" + excerpt }
                if end != lower.endIndex { excerpt += "…" }
                return excerpt
            }
        }
        return doc.metadata.summary
    }

    // MARK: - Loading

    private func loadAll() -> [String: HelpDocument] {
        var loaded: [String: HelpDocument] = [:]
        for topic in HelpTopic.allCases {
            guard let url = Bundle.main.url(forResource: topic.slug, withExtension: "md") else {
                Self.log.error("Missing bundled help doc: \(topic.slug, privacy: .public).md")
                assertionFailure("Help topic \(topic.slug) has no backing Documentation/\(topic.slug).md")
                continue
            }
            do {
                let raw = try String(contentsOf: url, encoding: .utf8)
                loaded[topic.slug] = HelpDocument.parse(raw: raw, fallbackSlug: topic.slug)
            } catch {
                Self.log.error("Failed reading \(topic.slug, privacy: .public).md: \(error.localizedDescription, privacy: .public)")
            }
        }
        Self.log.info("Loaded \(loaded.count, privacy: .public) help documents")
        return loaded
    }
}

/// A sidebar / Help-menu grouping: a section heading and its ordered topics.
struct HelpSection: Identifiable, Hashable {
    let title: String
    let topics: [HelpTopic]
    var id: String { title }
}

struct HelpSearchResult: Identifiable, Hashable {
    let slug: String
    let title: String
    let summary: String
    let snippet: String
    let score: Int
    var id: String { slug }
}
