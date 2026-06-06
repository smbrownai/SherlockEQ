import SwiftUI

/// The Phase-2 search + import surface. Lives inside the Profile
/// Detail editor's Headphone correction section. Search input filters
/// the in-memory index (no per-keystroke network traffic); selecting
/// a row triggers the on-demand fetch + parse + cache through
/// `AutoEQRemoteService`, then adds the result to
/// `AutoEQSavedProfilesStore`.
///
/// The view is intentionally compact — search field + result list +
/// inline error states, no modal sheets. Errors land on the row that
/// triggered them and stay until the user clears or retries.
struct AutoEQSearchView: View {

    @EnvironmentObject private var remote: AutoEQRemoteService
    @EnvironmentObject private var savedStore: AutoEQSavedProfilesStore

    /// Called when a fetch + import succeeds. The parent uses this to
    /// optionally auto-apply the freshly-imported correction to the
    /// active hearing profile. Per spec: import does NOT auto-apply by
    /// default; the parent treats this purely as a "did import" signal.
    var onImported: ((AutoEQSavedProfilesStore.SavedEntry) -> Void)?

    @State private var query: String = ""
    /// Rows mid-fetch — keyed by AutoEQ catalog `path` so the spinner
    /// only spins on the selected row, not every row.
    @State private var loadingPaths: Set<String> = []
    /// Most-recent fetch error per row, so the row can show inline
    /// copy + a Retry affordance. Cleared on success or row tap.
    @State private var errorByPath: [String: AutoEQRemoteService.AutoEQFetchError] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            searchField
            if let indexError = remote.indexError, remote.index == nil {
                indexErrorBanner(indexError)
            } else {
                resultList
            }
        }
        .task {
            // First-time appearance: trigger the index fetch if the
            // cache is missing or stale. The view's loading hint
            // surfaces the in-flight state; failure falls back to
            // whatever's already cached.
            if remote.indexNeedsRefresh {
                await remote.refreshIndex()
            }
        }
    }

    // MARK: - Header / search field

    @ViewBuilder private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass.circle.fill")
                .foregroundStyle(.tint)
            Text("Import from AutoEQ")
                .font(.callout.weight(.semibold))
            Spacer()
            if remote.isLoadingIndex {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Refreshing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let count = remote.index?.entries.count, count > 0 {
                Text("\(count.formatted()) profiles")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)
            TextField(
                remote.isLoadingIndex && remote.index == nil
                    ? "Loading headphone library…"
                    : "Search 6,000+ headphone profiles…",
                text: $query
            )
            .textFieldStyle(.plain)
            .disableAutocorrection(true)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.10))
        )
    }

    // MARK: - Result list

    @ViewBuilder private var resultList: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 2 {
            Text("Type at least two characters to search.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
                .padding(.top, 2)
        } else {
            let matches = filteredMatches(for: trimmed)
            if matches.visible.isEmpty {
                Text("No matches for \"\(trimmed)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
                    .padding(.top, 2)
            } else {
                resultsScrollView(matches: matches)
            }
        }
    }

    @ViewBuilder
    private func resultsScrollView(matches: FilteredMatches) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(matches.visible) { entry in
                    resultRow(entry)
                    Divider().padding(.leading, 12)
                }
                if matches.overflowCount > 0 {
                    overflowFooter(visible: matches.visible.count, total: matches.totalCount)
                }
            }
        }
        .frame(maxHeight: 280)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    @ViewBuilder private func resultRow(_ entry: AutoEQIndexEntry) -> some View {
        let isLoading = loadingPaths.contains(entry.path)
        let isSaved = savedStore.contains(path: entry.path)
        let error = errorByPath[entry.path]
        Button {
            if !isLoading { fetchAndImport(entry) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("\(entry.source) · \(entry.type)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isLoading {
                        ProgressView().controlSize(.mini)
                    } else if isSaved {
                        Label("Imported", systemImage: "checkmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.green)
                            .help("Already in your saved profiles")
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                if let error {
                    errorRow(error, for: entry)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    @ViewBuilder
    private func errorRow(_ error: AutoEQRemoteService.AutoEQFetchError, for entry: AutoEQIndexEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption2)
            Text(errorCopy(error))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Retry") { fetchAndImport(entry) }
                .buttonStyle(.borderless)
                .controlSize(.mini)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func overflowFooter(visible: Int, total: Int) -> some View {
        HStack {
            Spacer()
            Text("Showing \(visible) of \(total.formatted()) results — keep typing to narrow")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
        // Per spec: not tappable.
    }

    @ViewBuilder
    private func indexErrorBanner(_ error: AutoEQRemoteService.AutoEQFetchError) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("AutoEQ library unavailable")
                    .font(.callout.weight(.medium))
                Text(errorCopy(error))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Retry") {
                Task { await remote.refreshIndex(forceWhenLoading: true) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(remote.isLoadingIndex)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.orange.opacity(0.10))
        )
    }

    // MARK: - Matching

    private struct FilteredMatches {
        let visible: [AutoEQIndexEntry]
        let totalCount: Int
        var overflowCount: Int { totalCount - visible.count }
    }

    private static let maxVisibleResults = 50

    private func filteredMatches(for query: String) -> FilteredMatches {
        guard let entries = remote.index?.entries else {
            return FilteredMatches(visible: [], totalCount: 0)
        }
        // Tokenize on whitespace and AND every substring match. A
        // single-substring contains was too brittle against catalog
        // entries with quirky spacing — typing "DT 770 Pro X" missed
        // "Beyerdynamic DT770 Pro X Limited Edition" because of the
        // joined "DT770". Tokenizing both sides treats whitespace as
        // ignorable in the user's intent.
        let tokens = query
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else {
            return FilteredMatches(visible: [], totalCount: 0)
        }
        var matches: [AutoEQIndexEntry] = []
        for entry in entries {
            let haystack = "\(entry.name.lowercased()) \(entry.source.lowercased())"
            var allHit = true
            for token in tokens where !haystack.contains(token) {
                allHit = false
                break
            }
            if allHit { matches.append(entry) }
        }
        let visible = Array(matches.prefix(Self.maxVisibleResults))
        return FilteredMatches(visible: visible, totalCount: matches.count)
    }

    // MARK: - Fetch + import

    private func fetchAndImport(_ entry: AutoEQIndexEntry) {
        errorByPath[entry.path] = nil
        loadingPaths.insert(entry.path)
        Task {
            defer { loadingPaths.remove(entry.path) }
            do {
                let profile = try await remote.fetchProfile(for: entry)
                let saved = AutoEQSavedProfilesStore.SavedEntry(
                    path: entry.path,
                    name: entry.name,
                    source: entry.source,
                    type: entry.type,
                    importedAt: Date()
                )
                savedStore.add(saved)
                _ = profile  // referenced so the compiler doesn't elide the fetch path
                onImported?(saved)
            } catch let error as AutoEQRemoteService.AutoEQFetchError {
                errorByPath[entry.path] = error
            } catch {
                errorByPath[entry.path] = .other(error.localizedDescription)
            }
        }
    }

    // MARK: - Error copy

    private func errorCopy(_ error: AutoEQRemoteService.AutoEQFetchError) -> String {
        switch error {
        case .offline:
            return "Can't reach AutoEQ right now. Try again when connected."
        case .rateLimited:
            return "AutoEQ fetch temporarily unavailable. Try again in a few minutes."
        case .notFound:
            return "Profile not found. It may have been renamed in AutoEQ."
        case .parseFailure:
            return "Could not read this profile. Try a different measurement source."
        case .other(let description):
            return description
        }
    }
}

/// Compact saved-profiles list used inside the Headphone correction
/// section. Each row shows the headphone name, source badge, import
/// recency, and offers Apply / Delete. The currently-applied row
/// (matched by name to the active profile's autoEQName) is
/// highlighted.
struct AutoEQSavedProfilesList: View {

    @EnvironmentObject private var remote: AutoEQRemoteService
    @EnvironmentObject private var savedStore: AutoEQSavedProfilesStore

    let profile: HearingProfile
    var onApply: (AutoEQSavedProfilesStore.SavedEntry) -> Void

    var body: some View {
        let entries = savedStore.entries
        if entries.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Saved profiles")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(entries.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    let appliedPath = savedStore.appliedPath(in: profile)
                    ForEach(entries) { entry in
                        savedRow(entry, isActive: entry.path == appliedPath)
                        if entry != entries.last {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.secondary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
                )
            }
        }
    }

    @ViewBuilder
    private func savedRow(_ entry: AutoEQSavedProfilesStore.SavedEntry, isActive: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "headphones")
                .foregroundStyle(isActive ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    sourceBadge(entry.source)
                    Text(entry.type)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(importedLabel(entry.importedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(isActive ? "Active" : "Apply") {
                onApply(entry)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isActive)
            Button {
                savedStore.remove(path: entry.path, service: remote)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove from saved profiles")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isActive
                ? Color.accentColor.opacity(0.08)
                : Color.clear
        )
    }

    private func sourceBadge(_ source: String) -> some View {
        Text(source)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(Color.secondary.opacity(0.18))
            )
    }

    private func importedLabel(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 7 * 24 * 60 * 60 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
