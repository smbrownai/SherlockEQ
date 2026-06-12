import SwiftUI

/// Equalizer section of the main window — shows the EQ view that
/// matches the active profile's `eqMode`. The four modes (Simple,
/// Speech, Advanced, Expert) are storage views onto one underlying
/// band array, not stackable layers — the profile commits to one
/// mental model. Mode picker lives on Profile Detail.
struct EqualizerView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var audioState: AudioState

    var body: some View {
        let activeProfile = audioState.activeProfile(in: profileStore)
        let mode = activeProfile?.eqMode ?? .simple

        VStack(spacing: 0) {
            // Factory presets are editable in place; edits to one can be
            // reverted from Profile Detail ("Reset to Factory Default") or
            // globally via "Restore Factory Presets". No lock here.
            Group {
                switch mode {
                case .simple:   SimpleEQView()
                case .speech:   SpeechEQView()
                case .advanced: AdvancedEQView()
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
    }
}
