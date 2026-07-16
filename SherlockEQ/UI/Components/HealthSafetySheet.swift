import SwiftUI

/// The consolidated Health & Safety disclosure, presented as a native sheet
/// from the sidebar item and every compact disclosure chip. Content comes
/// entirely from `HealthSafetyDisclosure` (single source of truth). Calm,
/// scannable sections rather than one dense legal paragraph.
struct HealthSafetySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(HealthSafetyDisclosure.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(HealthSafetyDisclosure.sections) { section in
                        sectionView(section)
                    }

                    learnMore
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Comfortable readable width; grows with the sheet but never so wide
        // that lines become hard to scan.
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 680,
               minHeight: 520, idealHeight: 660)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "heart.text.square")
                .font(.title2)
                .foregroundStyle(.tint)
            Text(HealthSafetyDisclosure.title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private func sectionView(_ section: HealthSafetyDisclosure.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(section.title)
                    .font(.headline)
            } icon: {
                // Icon is decorative — the heading text carries the meaning.
                Image(systemName: section.symbol)
                    .foregroundStyle(.tint)
            }
            .accessibilityAddTraits(.isHeader)

            // No per-section "Learn more" — a link under every section turned
            // the sheet into a wall of links and pulled the eye away from the
            // disclosure itself. All Help links are gathered at the bottom.
            ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var learnMore: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Learn more in Help")
                    .font(.headline)
            } icon: {
                Image(systemName: "questionmark.circle").foregroundStyle(.tint)
            }
            .accessibilityAddTraits(.isHeader)

            ForEach(HealthSafetyDisclosure.learnMoreTopics, id: \.topic) { entry in
                Button {
                    openHelp(entry.topic)
                } label: {
                    Label(entry.label, systemImage: "book")
                        .font(.callout)
                }
                .buttonStyle(.link)
                .accessibilityLabel("Open Help: \(entry.label)")
            }
        }
        .padding(.top, 2)
    }

    private func openHelp(_ topic: HelpTopic) {
        // Dismiss the modal sheet, then bring up the Help window so the user
        // isn't juggling a modal on top of a window.
        dismiss()
        HelpCenter.shared.open(topic: topic)
    }
}
