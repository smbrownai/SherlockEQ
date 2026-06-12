import SwiftUI

/// Audiogram section of the main window. Edits the *active* profile's
/// per-ear audiograms. Derived `EQBand`s are persisted alongside every change
/// so Session 9's audio wiring can pick them up directly.
struct AudiogramView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var audioState: AudioState

    private enum EarTab: String, CaseIterable, Hashable {
        case left = "Left ear"
        case right = "Right ear"
    }
    @State private var tab: EarTab = .left

    var body: some View {
        if let profile = audioState.activeProfile(in: profileStore) {
            content(profile)
        } else {
            ContentUnavailableView(
                "No active profile",
                systemImage: "ear",
                description: Text("Make a profile active from the Profiles section to edit its audiogram.")
            )
        }
    }

    @ViewBuilder private func content(_ profile: HearingProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(profile)
                earPicker
                chartCard(profile)
                editorCard(profile)
                previewCard(profile)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Audiogram — \(profile.name)")
    }

    // MARK: - Sections

    private func header(_ profile: HearingProfile) -> some View {
        HStack(spacing: 14) {
            Image(systemName: profile.symbol)
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("Editing \(profile.name)").font(.title3.weight(.semibold))
                Text("Enter the dB HL values from your audiologist report, or drag points on the chart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HelpContextButton(.audiogramProfiles, label: "audiogram and hearing profiles")
        }
    }

    private var earPicker: some View {
        Picker("", selection: $tab) {
            ForEach(EarTab.allCases, id: \.self) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
    }

    @ViewBuilder private func chartCard(_ profile: HearingProfile) -> some View {
        card {
            Text(tab.rawValue + " — threshold chart")
                .font(.subheadline.weight(.semibold))
            AudiogramChartView(
                thresholds: audiogramBinding(for: profile),
                earColor: earColor
            )
        }
    }

    @ViewBuilder private func editorCard(_ profile: HearingProfile) -> some View {
        card {
            Text("Numeric entry")
                .font(.subheadline.weight(.semibold))
            ThresholdEditor(
                thresholds: audiogramBinding(for: profile),
                earColor: earColor
            )
        }
    }

    @ViewBuilder private func previewCard(_ profile: HearingProfile) -> some View {
        card {
            EQPreviewView(
                leftBands: profile.leftEar.bands,
                rightBands: profile.rightEar.bands,
                compensationFactor: profile.compensationFactor
            )
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private var earColor: Color { tab == .left ? audioState.leftEarColor : audioState.rightEarColor }

    /// Binding that reads/writes the active-tab ear's audiogram thresholds and
    /// rebuilds the matching EQ bands on every mutation so the derived curve
    /// (and Session 9's engine application) stays in sync.
    private func audiogramBinding(for profile: HearingProfile) -> Binding<[AudiogramPoint]> {
        Binding(
            get: { tab == .left ? profile.leftEar.thresholds : profile.rightEar.thresholds },
            set: { newPoints in
                var updated = profile
                let bands = AudiogramConversion.bands(
                    for: newPoints,
                    compensationFactor: updated.compensationFactor
                )
                if tab == .left {
                    updated.leftEar.thresholds = newPoints
                    updated.leftEar.bands = bands
                } else {
                    updated.rightEar.thresholds = newPoints
                    updated.rightEar.bands = bands
                }
                try? profileStore.save(updated)
            }
        )
    }
}
