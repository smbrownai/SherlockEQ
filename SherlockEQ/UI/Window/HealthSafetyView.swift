import SwiftUI

/// The consolidated Health & Safety disclosure, as a normal detail page.
///
/// It used to be a sheet. Nothing here asks for a decision, a confirmation, or
/// an acknowledgement — it's reference material — and a modal claims otherwise:
/// it interrupts, it has to be dismissed, and it implies the app is waiting on
/// you. This is documentation, so it reads like documentation and you leave it
/// the way you leave any page, by choosing something else in the sidebar.
///
/// The urgent-at-the-moment warnings still exist, and still belong in the
/// moment — `SafetyNote` on the Equalizer and Audiogram screens, the exposure
/// banners on Safe Listening. Those are contextual and small. This page is
/// where the whole picture lives when someone goes looking for it.
///
/// Content is entirely `HealthSafetyDisclosure` (single source of truth), so
/// this file is presentation only.
struct HealthSafetyView: View {

    /// Prose wants a measure, not a window. Long lines are hard to track back
    /// to the next line's start, and the detail column is ~1015 pt with the
    /// inspector closed — wide enough to make that genuinely uncomfortable.
    /// The column is leading-aligned rather than centred so it lines up with
    /// every other screen's content.
    private static let readableWidth: CGFloat = 680

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                Text(HealthSafetyDisclosure.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(HealthSafetyDisclosure.sections) { section in
                    sectionView(section)
                }

                learnMore
            }
            .frame(maxWidth: Self.readableWidth, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// No Done button, and no toolbar — the sidebar selection is the way out.
    private var header: some View {
        Label {
            Text(HealthSafetyDisclosure.title)
                .font(.title2.weight(.semibold))
        } icon: {
            Image(systemName: "heart.text.square")
                .font(.title2)
                .foregroundStyle(.tint)
        }
        .accessibilityAddTraits(.isHeader)
        .padding(.bottom, 2)
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

            // No per-section "Learn more" — a link under every section pulled
            // the eye away from the disclosure itself. Help links are gathered
            // at the bottom.
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
                    // No dismiss first — this is a page, so the Help window
                    // opens alongside it and the user can come back to a
                    // screen that never went away.
                    HelpCenter.shared.open(topic: entry.topic)
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
}
