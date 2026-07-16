import SwiftUI

/// Status chip for the acclimatization ramp (spec §5 / `AcclimatizationRamp`):
/// visible only while a profile's correction is still ramping toward full
/// strength. Mounted on the Audiogram screen (full explanation) and in
/// Profile Detail's Tuning section (compact row).
///
/// The ramp is labeled, never silent (Design note 5): the user always sees
/// which day they're on, what strength is applied right now, and has a
/// one-click exit.
struct AcclimatizationChip: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore
    /// Explicit subject for surfaces that edit a possibly-non-active
    /// profile (Profile Detail). Nil → the active profile (Audiogram).
    var subject: HearingProfile? = nil
    /// Tighter layout without the explanatory paragraph (Profile Detail).
    var compact: Bool = false

    var body: some View {
        if let profile = subject ?? audioState.activeProfile(in: profileStore),
           let start = profile.acclimatizationStartDate,
           profile.isAcclimatizing() {
            let day = AcclimatizationRamp.dayNumber(start: start)
            let percent = Int((profile.effectiveCorrectionStrength() * 100).rounded())
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(.tint)
                    Text("Gradual adjustment: day \(day) of \(Int(AcclimatizationRamp.durationDays)) — \(percent) % strength.")
                        .font(compact ? .caption : .callout)
                    Spacer()
                    Button("Use full strength now") {
                        skipRamp(profile)
                    }
                    .controlSize(.small)
                    .help("End the gradual ramp now and apply the adjustment at its full target strength.")
                }
                if !compact {
                    Text("New hearing adjustments can initially sound unfamiliar. SherlockEQ can introduce this adjustment gradually over three weeks. You may use full strength at any time.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(compact ? 8 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(0.30))
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Gradual adjustment, day \(day) of \(Int(AcclimatizationRamp.durationDays)), \(percent) percent strength.")
        }
    }

    private func skipRamp(_ profile: HearingProfile) {
        var updated = profile
        updated.acclimatizationStartDate = nil
        try? profileStore.save(updated, actionName: "Skip acclimatization")
    }
}
