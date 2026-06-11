import SwiftUI

/// A deliberately small markdown block renderer for help articles.
///
/// We don't pull in a full CommonMark engine: the documentation uses a
/// fixed, known subset (ATX headings, paragraphs, bullet/numbered lists,
/// fenced code, blockquotes, horizontal rules, footnote definitions).
/// Inline formatting (bold/italic/code/links) is delegated to Foundation's
/// `AttributedString(markdown:)`, which SwiftUI's `Text` renders natively —
/// including tappable links routed through the environment's `openURL`.
///
/// Internal cross-references are written in source as `[label](help:slug)`
/// or wiki-style `[[slug]]`; both resolve to the `help:` URL scheme that
/// `HelpCenter.handle(url:)` intercepts for in-window navigation.
enum HelpBlock: Identifiable, Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    case code(String)
    case quote([String])
    case rule
    /// `[^1]: …` definitions, grouped and rendered as a footnote list.
    case footnotes([(label: String, text: String)])
    /// GFM pipe table: a header row plus zero or more body rows. Cells
    /// carry raw inline markdown, rendered per-cell at draw time.
    case table(header: [String], rows: [[String]])

    var id: String {
        switch self {
        case .heading(let l, let t): return "h\(l):\(t)"
        case .paragraph(let t): return "p:\(t.prefix(48))\(t.count)"
        case .bullets(let items): return "ul:\(items.count):\(items.first ?? "")"
        case .numbered(let items): return "ol:\(items.count):\(items.first ?? "")"
        case .code(let c): return "code:\(c.prefix(24))\(c.count)"
        case .quote(let lines): return "q:\(lines.count):\(lines.first ?? "")"
        case .rule: return "hr"
        case .footnotes(let f): return "fn:\(f.count)"
        case .table(let header, let rows): return "tbl:\(header.joined(separator: "|")):\(rows.count)"
        }
    }

    static func == (lhs: HelpBlock, rhs: HelpBlock) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum MarkdownParser {

    /// Split a markdown body into renderable blocks. Single pass over
    /// lines with a small amount of look-ahead state for fences and lists.
    static func parse(_ markdown: String) -> [HelpBlock] {
        let normalized = preprocessLinks(markdown)
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [HelpBlock] = []

        var i = 0
        var paragraph: [String] = []
        var footnotes: [(label: String, text: String)] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }
        func flushFootnotes() {
            guard !footnotes.isEmpty else { return }
            blocks.append(.footnotes(footnotes))
            footnotes.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if trimmed.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                blocks.append(.code(code.joined(separator: "\n")))
                i += 1
                continue
            }

            // Blank line ends the current paragraph.
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Horizontal rule.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph(); flushFootnotes()
                blocks.append(.rule)
                i += 1
                continue
            }

            // ATX heading.
            if let (level, text) = headingComponents(trimmed) {
                flushParagraph(); flushFootnotes()
                blocks.append(.heading(level: level, text: text))
                i += 1
                continue
            }

            // Footnote definition: `[^label]: text`.
            if let fn = footnoteDefinition(trimmed) {
                flushParagraph()
                footnotes.append(fn)
                i += 1
                continue
            }

            // Blockquote run.
            if trimmed.hasPrefix(">") {
                flushParagraph(); flushFootnotes()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    quote.append(String(q.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quote))
                continue
            }

            // Unordered list run.
            if isBullet(trimmed) {
                flushParagraph(); flushFootnotes()
                var items: [String] = []
                while i < lines.count, isBullet(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripBullet(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.bullets(items))
                continue
            }

            // Ordered list run.
            if isNumbered(trimmed) {
                flushParagraph(); flushFootnotes()
                var items: [String] = []
                while i < lines.count, isNumbered(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripNumber(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.numbered(items))
                continue
            }

            // GFM pipe table: a header row immediately followed by a
            // delimiter row (`| --- | --- |`). Without the delimiter on the
            // next line a lone `|` is just paragraph text, so this can't
            // swallow ordinary prose.
            if trimmed.contains("|"),
               i + 1 < lines.count,
               isTableDelimiter(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph(); flushFootnotes()
                let header = tableCells(trimmed)
                i += 2  // consume header + delimiter
                var rows: [[String]] = []
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    rows.append(tableCells(row))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // Default: accumulate into the running paragraph.
            paragraph.append(trimmed)
            i += 1
        }

        flushParagraph()
        flushFootnotes()
        return blocks
    }

    // MARK: - Inline helpers

    /// Convert wiki links `[[slug]]` → `[Title](help:slug)` and inline
    /// footnote markers `[^1]` → `[1]` before block parsing. The title for
    /// a wiki link is derived from the slug; the resolved title in the
    /// window comes from the live library at click time, so a humanised
    /// slug here is only the visible label.
    private static func preprocessLinks(_ markdown: String) -> String {
        var out = markdown
        // [[slug]] → [Humanised Slug](help:slug)
        if let re = try? NSRegularExpression(pattern: "\\[\\[([a-z0-9-]+)\\]\\]") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let slug = ns.substring(with: m.range(at: 1))
                let label = slug.replacingOccurrences(of: "-", with: " ").capitalized
                result += "[\(label)](help:\(slug))"
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        // Inline footnote markers [^1] → [1] (definitions handled separately).
        out = out.replacingOccurrences(
            of: "\\[\\^([0-9a-zA-Z]+)\\](?!:)",
            with: "[$1]",
            options: .regularExpression
        )
        return out
    }

    private static func headingComponents(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1; idx = line.index(after: idx)
        }
        guard idx < line.endIndex, line[idx] == " " else { return nil }
        return (level, String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces))
    }

    private static func footnoteDefinition(_ line: String) -> (label: String, text: String)? {
        guard line.hasPrefix("[^") else { return nil }
        guard let close = line.range(of: "]:") else { return nil }
        let label = String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
        let text = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (label, text)
    }

    /// A GFM table delimiter row: every cell is only dashes / colons
    /// (e.g. `---`, `:--`, `:-:`). Used as the signal that the preceding
    /// line was a header rather than ordinary text.
    private static func isTableDelimiter(_ line: String) -> Bool {
        guard line.contains("-"), line.contains("|") else { return false }
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    /// Split one table row into trimmed cells, dropping the optional
    /// leading / trailing pipe. A backslash-escaped pipe (`\|`) is treated
    /// as literal content, not a column boundary.
    private static func tableCells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        let sentinel = "\u{0001}"
        s = s.replacingOccurrences(of: "\\|", with: sentinel)
        return s.components(separatedBy: "|").map {
            $0.replacingOccurrences(of: sentinel, with: "|")
                .trimmingCharacters(in: .whitespaces)
        }
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }
    private static func stripBullet(_ line: String) -> String {
        String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }
    private static func isNumbered(_ line: String) -> Bool {
        guard let dot = line.firstIndex(of: ".") else { return false }
        let prefix = line[line.startIndex..<dot]
        return !prefix.isEmpty && prefix.allSatisfy(\.isNumber) && line.index(after: dot) < line.endIndex && line[line.index(after: dot)] == " "
    }
    private static func stripNumber(_ line: String) -> String {
        guard let dot = line.firstIndex(of: ".") else { return line }
        return String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
    }

    /// Render an inline markdown string to an `AttributedString`,
    /// preserving links / emphasis. Falls back to plain text on parse
    /// failure so a malformed run never crashes the renderer.
    static func inline(_ string: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: string, options: options)) ?? AttributedString(string)
    }
}

// MARK: - SwiftUI view

/// Renders a help document's body as a vertical stack of styled blocks.
/// Internal `help:` links route through `HelpCenter`; external links open
/// in the browser. The `openURL` environment override is installed once
/// at the top so every nested `Text` link funnels through it.
struct MarkdownArticleView: View {
    let markdown: String
    @EnvironmentObject private var help: HelpCenter

    private var blocks: [HelpBlock] { MarkdownParser.parse(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            switch help.handle(url: url) {
            case .handledInternally:
                return .handled
            case .openExternally(let external):
                return .systemAction(external)
            }
        })
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: HelpBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .paragraph(let text):
            Text(MarkdownParser.inline(text))
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: "•", text: item)
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    listRow(marker: "\(idx + 1).", text: item)
                }
            }
        case .code(let code):
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        case .quote(let lines):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(.tint).frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(MarkdownParser.inline(line))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 4)
        case .rule:
            Divider().padding(.vertical, 6)
        case .footnotes(let notes):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("[\(note.label)]")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(MarkdownParser.inline(note.text))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 4)
        case .table(let header, let rows):
            tableView(header: header, rows: rows)
        }
    }

    @ViewBuilder
    private func tableView(header: [String], rows: [[String]]) -> some View {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 9) {
            GridRow {
                ForEach(0..<columnCount, id: \.self) { c in
                    Text(MarkdownParser.inline(c < header.count ? header[c] : ""))
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { c in
                        Text(MarkdownParser.inline(c < row.count ? row[c] : ""))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        let inline = MarkdownParser.inline(text)
        switch level {
        case 1:
            Text(inline).font(.largeTitle.weight(.bold)).padding(.bottom, 2)
        case 2:
            Text(inline).font(.title2.weight(.semibold)).padding(.top, 10)
        case 3:
            Text(inline).font(.title3.weight(.semibold)).padding(.top, 6)
        default:
            Text(inline).font(.headline).padding(.top, 4)
        }
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 16, alignment: .trailing)
            Text(MarkdownParser.inline(text))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
