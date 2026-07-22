//
//  HelpSystemTests.swift
//  SherlockEQTests
//
//  Verifies the help documentation pipeline end to end: every topic
//  has a bundled, parseable article; front-matter and markdown parse
//  correctly; and search ranks/synonym-expands as designed.
//

import Testing
import Foundation
@testable import SherlockEQ

@MainActor
struct HelpSystemTests {

    // MARK: - Library loading

    @Test func everyTopicHasABackingDocument() {
        let library = HelpLibrary()
        for topic in HelpTopic.allCases {
            #expect(library.document(for: topic) != nil, "missing bundled doc for \(topic.slug)")
        }
        #expect(library.documents.count == HelpTopic.allCases.count)
    }

    @Test func loadedDocumentsHaveTitleAndMatchingSlug() {
        let library = HelpLibrary()
        for topic in HelpTopic.allCases {
            let doc = library.document(for: topic)
            #expect(doc?.slug == topic.slug)
            #expect(!(doc?.title.isEmpty ?? true), "empty title for \(topic.slug)")
        }
    }

    @Test func hearingTopicsCarryMedicalBoundaryLanguage() {
        // Acceptance criterion: hearing-related topics state the
        // not-a-medical-device boundary explicitly.
        let library = HelpLibrary()
        let mustDisclaim: [HelpTopic] = [
            .audiogramProfiles, .tinnitusToneMatching, .safetyLimits, .gettingStarted,
        ]
        for topic in mustDisclaim {
            let body = library.document(for: topic)?.body.lowercased() ?? ""
            #expect(body.contains("not a medical device") || body.contains("not medical advice"),
                    "\(topic.slug) is missing medical-boundary language")
        }
    }

    @Test func researchTopicsHaveReferences() {
        // Acceptance criterion: research/citation sections exist for the
        // audiogram, tinnitus, headphone, VU, and DSP topics.
        let library = HelpLibrary()
        let mustCite: [HelpTopic] = [
            .audiogramProfiles, .tinnitusToneMatching, .headphoneCorrection,
            .vuMeters, .parametricEQ, .references,
        ]
        for topic in mustCite {
            let body = library.document(for: topic)?.body ?? ""
            #expect(body.contains("[^"), "\(topic.slug) has no footnote citations")
        }
    }

    // MARK: - Front-matter parsing

    @Test func parsesFrontMatterFields() {
        let raw = """
        ---
        title: "Audiogram & Hearing Profiles"
        slug: "audiogram-profiles"
        category: "Hearing-Aware Features"
        summary: "A summary line."
        keywords:
          - audiogram
          - hearing
          - thresholds
        related:
          - per-ear-eq
          - safety-limits
        ---

        # Body

        Hello.
        """
        let doc = HelpDocument.parse(raw: raw, fallbackSlug: "fallback")
        #expect(doc.title == "Audiogram & Hearing Profiles")
        #expect(doc.slug == "audiogram-profiles")
        #expect(doc.metadata.category == "Hearing-Aware Features")
        #expect(doc.metadata.summary == "A summary line.")
        #expect(doc.metadata.keywords == ["audiogram", "hearing", "thresholds"])
        #expect(doc.metadata.related == ["per-ear-eq", "safety-limits"])
        #expect(doc.body.hasPrefix("# Body"))
    }

    @Test func usesFallbackSlugWhenNoFrontMatter() {
        let doc = HelpDocument.parse(raw: "# Just a heading\n\nText.", fallbackSlug: "lonely")
        #expect(doc.slug == "lonely")
        #expect(doc.body.contains("Just a heading"))
    }

    // MARK: - Markdown block parsing

    @Test func parsesHeadingsBulletsCodeAndFootnotes() {
        let md = """
        # Title

        A paragraph.

        ## Section

        - one
        - two

        ```
        code here
        ```

        [^1]: A citation.
        """
        let blocks = MarkdownParser.parse(md)

        func hasHeading(_ level: Int) -> Bool {
            blocks.contains { if case .heading(let l, _) = $0 { return l == level }; return false }
        }
        #expect(hasHeading(1))
        #expect(hasHeading(2))
        #expect(blocks.contains { if case .bullets(let items) = $0 { return items == ["one", "two"] }; return false })
        #expect(blocks.contains { if case .code(let c) = $0 { return c.contains("code here") }; return false })
        #expect(blocks.contains { if case .footnotes(let f) = $0 { return f.first?.label == "1" }; return false })
    }

    @Test func bulletItemsJoinWrappedContinuationLines() {
        // Source docs hard-wrap long bullet text across lines for editor
        // readability (see analog-control-unit.md's "How the knobs map").
        // A continuation line has no "- " marker, so it must fold onto the
        // previous item rather than ending the list and falling out as a
        // stray unindented paragraph.
        let md = """
        - **Volume** → the macOS system output volume (via the system, not the app's
          internal gain). This reaches outside SherlockEQ.
        - **Output** → switches the macOS default output device.
        """
        let blocks = MarkdownParser.parse(md)
        #expect(blocks.count == 1)
        guard case .bullets(let items)? = blocks.first else {
            Issue.record("expected a single bullets block"); return
        }
        #expect(items.count == 2)
        #expect(items[0].contains("Volume"))
        #expect(items[0].contains("This reaches outside SherlockEQ."))
        #expect(items[1] == "**Output** → switches the macOS default output device.")
    }

    @Test func bulletListStillEndsAtBlankLineOrNewBlock() {
        let md = """
        - one
        - two

        A paragraph after the list.
        """
        let blocks = MarkdownParser.parse(md)
        #expect(blocks.contains { if case .bullets(let items) = $0 { return items == ["one", "two"] }; return false })
        #expect(blocks.contains { if case .paragraph(let t) = $0 { return t == "A paragraph after the list." }; return false })
    }

    @Test func numberedItemsJoinWrappedContinuationLines() {
        let md = """
        1. **Set a comfortable tone level** — press Play and set a quiet
           level; loudness doesn't matter.
        2. **Sweep for the closest pitch** — drag across the range.
        """
        let blocks = MarkdownParser.parse(md)
        guard case .numbered(let items)? = blocks.first else {
            Issue.record("expected a single numbered block"); return
        }
        #expect(items.count == 2)
        #expect(items[0].contains("loudness doesn't matter."))
        #expect(items[1] == "**Sweep for the closest pitch** — drag across the range.")
    }

    @Test func preprocessesWikiLinksAndInlineFootnotes() {
        // [[slug]] becomes an internal help: link; [^1] inline marker is
        // de-referenced to [1] so it doesn't collide with definitions.
        let blocks = MarkdownParser.parse("See [[per-ear-eq]] and a marker[^1].")
        guard case .paragraph(let text)? = blocks.first else {
            Issue.record("expected a paragraph block"); return
        }
        #expect(text.contains("(help:per-ear-eq)"))
        #expect(text.contains("[1]"))
        #expect(!text.contains("[^1]"))
    }

    // MARK: - Search

    @Test func searchFindsExactAndSynonymMatches() {
        let library = HelpLibrary()
        // Everyday synonyms route to the technical article.
        #expect(library.search("ringing").contains { $0.slug == "tinnitus-tone-matching" })
        #expect(library.search("presets").contains { $0.slug == "profiles" })
        #expect(library.search("distortion").contains { $0.slug == "safety-limits" || $0.slug == "troubleshooting" })
        // Direct title hit ranks the audiogram article first.
        let audiogram = library.search("audiogram")
        #expect(audiogram.first?.slug == "audiogram-profiles")
    }

    @Test func emptyQueryReturnsNothing() {
        #expect(HelpLibrary().search("   ").isEmpty)
    }

    // MARK: - Navigation & link routing

    @Test func internalLinkNavigatesAndExternalLinkOpensOut() {
        let help = HelpCenter.shared
        help.navigate(to: HelpTopic.home.slug)

        if case .handledInternally = help.handle(url: URL(string: "help:vu-meters")!) {
            #expect(help.currentSlug == "vu-meters")
        } else {
            Issue.record("help: scheme should be handled internally")
        }

        if case .openExternally(let url) = help.handle(url: URL(string: "https://example.com")!) {
            #expect(url.host == "example.com")
        } else {
            Issue.record("external URL should open externally")
        }
    }

    @Test func backForwardHistoryWorks() {
        let help = HelpCenter.shared
        help.navigate(to: "index")
        help.navigate(to: "getting-started")
        help.navigate(to: "safety-limits")
        #expect(help.currentSlug == "safety-limits")
        #expect(help.canGoBack)

        help.goBack()
        #expect(help.currentSlug == "getting-started")
        help.goForward()
        #expect(help.currentSlug == "safety-limits")
    }
}
