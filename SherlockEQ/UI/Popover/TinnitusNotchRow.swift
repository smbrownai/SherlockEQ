import SwiftUI

/// Popover row for the tinnitus notch filter: on/off toggle + frequency label.
/// Full notch controls (depth, width) live in the main window's Expert EQ view.
struct TinnitusNotchRow: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore

    var body: some View {
        HStack(spacing: 8) {
            Text("Tinnitus Notch")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 100, alignment: .leading)
                .layoutPriority(1)

            Toggle("", isOn: toggleBinding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()

            Spacer(minLength: 0)

            Text(frequencyLabel)
                .font(.caption.monospaced())
                .foregroundStyle(notchEnabled ? .primary : .tertiary)
        }
        .disabled(audioState.activeProfile(in: profileStore) == nil)
    }

    /// "On" when either ear's notch is enabled. The popover is the
    /// 5-second surface; the per-ear story lives on the Tinnitus
    /// Notch screen, so we keep this binary.
    private var notchEnabled: Bool {
        guard let p = audioState.activeProfile(in: profileStore) else { return false }
        return p.leftNotch.enabled || p.rightNotch.enabled
    }

    /// Display the left ear's frequency as the representative value.
    /// Adds an "L/R" suffix when the two ears have different
    /// frequencies (separate-notch mode with distinct values) so the
    /// readout doesn't silently lie about a divergence.
    private var frequencyLabel: String {
        guard let profile = audioState.activeProfile(in: profileStore) else { return "—" }
        let lFreq = Int(profile.leftNotch.frequencyHz)
        let rFreq = Int(profile.rightNotch.frequencyHz)
        if profile.separateNotch && lFreq != rFreq {
            return "\(lFreq.formatted()) / \(rFreq.formatted()) Hz"
        }
        return "\(lFreq.formatted()) Hz"
    }

    /// Quick toggle writes both ears in lockstep regardless of
    /// `separateNotch` — the popover is for "turn it on" / "turn it
    /// off" not for fine per-ear management. Users who want
    /// independent enable states open the Tinnitus Notch screen.
    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { notchEnabled },
            set: { newValue in
                guard var p = audioState.activeProfile(in: profileStore) else { return }
                p.leftNotch.enabled = newValue
                p.rightNotch.enabled = newValue
                try? profileStore.save(p)
            }
        )
    }
}
