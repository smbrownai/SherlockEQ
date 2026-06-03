import SwiftUI

/// Stand-in detail panel for sidebar sections that don't have real content yet.
/// Used in Session 6 to give the sidebar a real shape before Sessions 7–17
/// fill in the individual views.
struct PlaceholderView: View {
    let title: String
    let summary: String
    let sessionRef: String   // e.g. "Session 8"
    let symbol: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(summary)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("Wiring: \(sessionRef)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
