import Foundation

/// One parsed help article: its front-matter metadata plus the raw
/// markdown body (front-matter stripped). The body is kept as a string
/// and rendered lazily by `MarkdownRenderer` only when the article is
/// displayed — parsing every article's blocks at launch would be wasted
/// work for the 20+ topics the user never opens in a session.
struct HelpDocument: Identifiable, Hashable, Sendable {
    let metadata: HelpMetadata
    /// Markdown source with the YAML front-matter block removed.
    let body: String

    var id: String { metadata.slug }
    var title: String { metadata.title }
    var slug: String { metadata.slug }

    /// Lowercased haystack used for full-text search ranking. Built once
    /// at load time so search doesn't re-lowercase every body on each keystroke.
    let searchHaystack: String
}

/// Front-matter fields for a help article. Mirrors the `---` YAML block
/// at the top of every `Documentation/*.md` file. All fields except
/// `title`/`slug` are optional so a thin placeholder still loads.
struct HelpMetadata: Hashable, Sendable {
    var title: String
    var slug: String
    var category: String
    var summary: String
    var keywords: [String]
    var related: [String]

    static func placeholder(slug: String) -> HelpMetadata {
        HelpMetadata(
            title: slug.replacingOccurrences(of: "-", with: " ").capitalized,
            slug: slug,
            category: "Uncategorized",
            summary: "",
            keywords: [],
            related: []
        )
    }
}

extension HelpDocument {

    /// Parse a raw markdown file (front-matter + body) into a document.
    /// The front-matter is a minimal YAML subset — `key: value` scalars
    /// plus simple `- item` lists for `keywords`/`related`. We hand-roll
    /// it rather than pull in a YAML dependency because the schema is
    /// fixed and tiny; anything the parser doesn't recognise is ignored
    /// rather than throwing, so a malformed field degrades gracefully.
    static func parse(raw: String, fallbackSlug: String) -> HelpDocument {
        var frontMatter = ""
        var body = raw

        // Front-matter is a leading `---` … `---` fence. Tolerate a BOM
        // or leading whitespace before the opening fence.
        let trimmed = raw.drop(while: { $0 == "\u{FEFF}" || $0 == "\n" })
        if trimmed.hasPrefix("---") {
            let afterOpen = trimmed.dropFirst(3)
            if let closeRange = afterOpen.range(of: "\n---") {
                frontMatter = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])
                let afterClose = afterOpen[closeRange.upperBound...]
                // Skip to the end of the closing fence's line.
                if let newline = afterClose.firstIndex(of: "\n") {
                    body = String(afterClose[afterClose.index(after: newline)...])
                } else {
                    body = ""
                }
            }
        }

        let meta = parseMetadata(frontMatter, fallbackSlug: fallbackSlug)
        let haystack = (
            meta.title + " " +
            meta.summary + " " +
            meta.keywords.joined(separator: " ") + " " +
            body
        ).lowercased()

        return HelpDocument(
            metadata: meta,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            searchHaystack: haystack
        )
    }

    private static func parseMetadata(_ yaml: String, fallbackSlug: String) -> HelpMetadata {
        var meta = HelpMetadata.placeholder(slug: fallbackSlug)
        guard !yaml.isEmpty else { return meta }

        var currentListKey: String?
        var keywords: [String] = []
        var related: [String] = []

        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let indented = line.first == " " || line.first == "\t" || line.first == "-"
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { continue }

            // A `- item` line continues the most-recently-seen list key.
            if stripped.hasPrefix("- "), indented, let key = currentListKey {
                let value = unquote(String(stripped.dropFirst(2)))
                if key == "keywords" { keywords.append(value) }
                else if key == "related" { related.append(value) }
                continue
            }

            guard let colon = stripped.firstIndex(of: ":") else { continue }
            let key = String(stripped[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = unquote(String(stripped[stripped.index(after: colon)...]).trimmingCharacters(in: .whitespaces))

            currentListKey = (value.isEmpty && (key == "keywords" || key == "related")) ? key : nil

            switch key {
            case "title": if !value.isEmpty { meta.title = value }
            case "slug": if !value.isEmpty { meta.slug = value }
            case "category": if !value.isEmpty { meta.category = value }
            case "summary": meta.summary = value
            case "keywords": if !value.isEmpty { keywords.append(contentsOf: splitInline(value)) }
            case "related": if !value.isEmpty { related.append(contentsOf: splitInline(value)) }
            default: break
            }
        }

        meta.keywords = keywords
        meta.related = related
        return meta
    }

    /// Support inline `[a, b]`-style or comma lists in addition to block lists.
    private static func splitInline(_ value: String) -> [String] {
        let inner = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return inner
            .split(separator: ",")
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    private static func unquote(_ s: String) -> String {
        var v = s
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")), v.count >= 2 {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }
}
