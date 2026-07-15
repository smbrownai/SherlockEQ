import SwiftUI

/// Equalizer section of the main window — shows the EQ surface that
/// matches the active profile's `eqMode`. Two surfaces (Graphic,
/// Parametric) edit one underlying band array; the segmented picker in
/// this screen's toolbar switches between them (it used to live on
/// Profile Detail, where its effect on THIS screen was hard to
/// discover). Switching is non-destructive — bands the other surface
/// wrote stay in storage, and Graphic surfaces any it can't edit via
/// its "Other filters" row.
struct EqualizerView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var audioState: AudioState

    var body: some View {
        let activeProfile = audioState.activeProfile(in: profileStore)
        let mode = activeProfile?.eqMode ?? .advanced

        VStack(spacing: 0) {
            // Headphone-correction device mismatch (spec §7) — shown above
            // whichever surface is active, since the correction shapes what
            // both of them display and hear.
            AutoEQMismatchRow()
                .padding(.horizontal, 24)
                .padding(.top, 12)
            // Factory presets are editable in place; edits to one can be
            // reverted from Profile Detail ("Reset to Factory Default") or
            // globally via "Restore Factory Presets". No lock here.
            Group {
                switch mode {
                case .advanced: GraphicEQView()
                case .expert:   ExpertEQView()
                }
            }

            // Upstream-EQ footnote. Other apps' equalizers (Music's EQ,
            // Sound Check, etc.) run inside those apps before the tap
            // captures the mix, so they stack underneath this curve and
            // are indistinguishable from the content itself — we can't
            // detect or compensate from the tap side, only educate.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("Equalizers inside other apps — like Music's EQ — shape the audio before it reaches SherlockEQ and stack with this curve. For predictable correction, keep other apps' equalizers flat.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
        }
        .navigationTitle("Equalizer")
        .toolbar {
            // Surface switch, next to the title where its effect is —
            // it swaps this entire screen. `.navigation` keeps it at the
            // leading edge beside "Equalizer"; the window-level Reference
            // Mode + monitor-panel controls keep the trailing edge to
            // themselves. Disabled (not hidden) with no active profile so
            // the control's existence stays discoverable.
            ToolbarItem(placement: .navigation) {
                if let profile = activeProfile {
                    surfacePicker(profile)
                } else {
                    surfacePickerDisabled
                }
            }
        }
    }

    /// `Graphic | Parametric` — writes the active profile's `eqMode`.
    /// Same non-destructive semantics as everywhere else: both surfaces
    /// edit one band array, so flipping back and forth loses nothing.
    private func surfacePicker(_ profile: HearingProfile) -> some View {
        Picker("EQ surface", selection: Binding(
            get: { profile.eqMode },
            set: { newMode in
                guard newMode != profile.eqMode else { return }
                var updated = profile
                updated.eqMode = newMode
                try? profileStore.save(updated, actionName: "Switch to \(newMode.label)")
            }
        )) {
            ForEach(EQMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Choose the editing surface: Graphic (12 sliders) or Parametric (full-control canvas). Both edit the same EQ — switching never loses settings.")
    }

    private var surfacePickerDisabled: some View {
        Picker("EQ surface", selection: .constant(EQMode.advanced)) {
            ForEach(EQMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(true)
    }
}
