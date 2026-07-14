import SwiftUI

/// The SherlockEQ Help window: a native three-region layout — sidebar
/// table of contents + search on the left, the rendered article on the
/// right, a version-stamped footer along the bottom. It's a thin view
/// over `HelpCenter`: all navigation state and content live there, so
/// the window can close and reopen without losing place.
struct HelpWindowView: View {
    @EnvironmentObject private var help: HelpCenter

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
        } detail: {
            articlePane
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if help.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                tableOfContents
            } else {
                searchResults
            }
            Divider()
            versionFooter
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search help", text: $help.searchText)
                .textFieldStyle(.plain)
            if !help.searchText.isEmpty {
                Button {
                    help.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var tableOfContents: some View {
        List(selection: selectionBinding) {
            ForEach(HelpLibrary.outline) { section in
                Section(section.title) {
                    ForEach(section.topics, id: \.self) { topic in
                        Label(help.library.title(for: topic.slug), systemImage: icon(for: topic))
                            .tag(topic.slug)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var searchResults: some View {
        let results = help.library.search(help.searchText)
        return Group {
            if results.isEmpty {
                ContentUnavailableView.search(text: help.searchText)
            } else {
                List(selection: selectionBinding) {
                    Section("\(results.count) result\(results.count == 1 ? "" : "s")") {
                        ForEach(results) { result in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.title).font(.callout.weight(.medium))
                                Text(result.snippet)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 2)
                            .tag(result.slug)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    /// Selecting a row navigates. We don't bind the List selection
    /// directly to `currentSlug` because navigation history needs the
    /// push semantics in `HelpCenter.navigate(to:)`.
    private var selectionBinding: Binding<String?> {
        Binding(
            get: { help.currentSlug },
            set: { if let slug = $0 { help.navigate(to: slug) } }
        )
    }

    private var versionFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").font(.caption2)
            Text("SherlockEQ \(help.appVersionString)")
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Documentation for SherlockEQ version \(help.appVersionString)")
    }

    // MARK: - Article

    @ViewBuilder
    private var articlePane: some View {
        if let doc = help.currentDocument {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Color.clear.frame(height: 0).id("top")
                        articleHeader(doc)
                        MarkdownArticleView(markdown: doc.body)
                        relatedFooter(doc)
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .softTopScrollEdge()
                .onChange(of: help.currentSlug) { _, _ in
                    proxy.scrollTo("top", anchor: .top)
                }
            }
            .toolbar { articleToolbar(doc) }
            .navigationTitle(doc.title)
        } else {
            ContentUnavailableView(
                "Article unavailable",
                systemImage: "doc.questionmark",
                description: Text("This help topic could not be loaded.")
            )
        }
    }

    private func articleHeader(_ doc: HelpDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(doc.metadata.category.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)
            if !doc.metadata.summary.isEmpty {
                Text(doc.metadata.summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func relatedFooter(_ doc: HelpDocument) -> some View {
        let related = doc.metadata.related.compactMap { slug in
            help.library.document(for: slug).map { (slug, $0.title) }
        }
        if !related.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Divider().padding(.vertical, 8)
                Text("Related topics")
                    .font(.headline)
                FlowChips(items: related) { slug, title in
                    Button {
                        help.navigate(to: slug)
                    } label: {
                        Text(title)
                            .font(.callout)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private func articleToolbar(_ doc: HelpDocument) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                help.goBack()
            } label: { Image(systemName: "chevron.left") }
                .disabled(!help.canGoBack)
                .help("Back")
            Button {
                help.goForward()
            } label: { Image(systemName: "chevron.right") }
                .disabled(!help.canGoForward)
                .help("Forward")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    copyLink(to: doc.slug)
                } label: {
                    Label("Copy Link to Topic", systemImage: "link")
                }
                Button {
                    copySection(doc)
                } label: {
                    Label("Copy Article Text", systemImage: "doc.on.doc")
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Share")
        }
    }

    private func copyLink(to slug: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("help:\(slug)", forType: .string)
    }

    private func copySection(_ doc: HelpDocument) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("# \(doc.title)\n\n\(doc.body)", forType: .string)
    }

    private func icon(for topic: HelpTopic) -> String {
        switch topic {
        case .home: return "house"
        case .gettingStarted: return "flag.checkered"
        case .featureGuide: return "list.bullet.rectangle"
        case .understandingEQ: return "waveform"
        case .gainVolume: return "speaker.wave.3"
        case .balance: return "scalemass"
        case .graphicEQ: return "slider.vertical.3"
        case .parametricEQ: return "slider.horizontal.below.square.filled.and.square"
        case .perEarEQ: return "ear"
        case .audiogramProfiles: return "chart.xyaxis.line"
        case .tinnitusToneMatching: return "tuningfork"
        case .headphoneCorrection: return "headphones"
        case .listeningComfort: return "waveform.badge.magnifyingglass"
        case .vuMeters: return "gauge.with.dots.needle.bottom.50percent"
        case .spectrumVisualization: return "waveform.path.ecg.rectangle"
        case .analogControlUnit: return "dial.medium"
        case .outputDevices: return "hifispeaker.and.appletv"
        case .profiles: return "person.crop.rectangle.stack"
        case .safetyLimits: return "exclamationmark.shield"
        case .privacy: return "lock.shield"
        case .troubleshooting: return "wrench.and.screwdriver"
        case .keyboardShortcuts: return "keyboard"
        case .commandLineTool: return "terminal"
        case .releaseNotes: return "sparkles"
        case .references: return "book.closed"
        }
    }
}

/// Minimal wrapping chip layout for the related-topics footer — `Layout`
/// avoids hard-coding a column count so chips reflow with window width.
private struct FlowChips<Data: RandomAccessCollection, Content: View>: View
where Data.Element == (String, String) {
    let items: Data
    @ViewBuilder let content: (String, String) -> Content

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, pair in
                content(pair.0, pair.1)
            }
        }
    }
}

/// A simple flow layout (left-to-right, wrapping) for chip rows.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
