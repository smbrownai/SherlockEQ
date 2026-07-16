import SwiftUI

/// Popover row for the tinnitus notch: state + frequency, and a switch.
///
/// Unlike Adaptive Comfort — three processors a single switch can't honestly
/// summarise — the notch is one filter at one pitch, so a quick on/off here is
/// both understandable and reversible: turning it back on restores the same
/// frequency it was configured at. Depth, width, and pitch matching live on
/// the Tinnitus Tools screen.
struct TinnitusNotchRow: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore

    var body: some View {
        HStack(spacing: 8) {
            Text("Tinnitus notch")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)
                .layoutPriority(1)

            Spacer(minLength: 0)

            // "Off · Configured at 4,000 Hz" — when off, the frequency is
            // still worth showing, but as configuration rather than as
            // something currently being applied.
            Text(stateLabel)
                .font(.caption.monospaced())
                .foregroundStyle(notchEnabled ? .primary : .tertiary)
                .lineLimit(1)

            Toggle("", isOn: toggleBinding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .disabled(audioState.activeProfile(in: profileStore) == nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tinnitus notch")
        .accessibilityValue(stateLabel)
    }

    /// "On" when either ear's notch is enabled. The per-ear story lives on the
    /// Tinnitus Tools screen, so we keep this binary.
    private var notchEnabled: Bool {
        guard let p = audioState.activeProfile(in: profileStore) else { return false }
        return p.leftNotch.enabled || p.rightNotch.enabled
    }

    /// `On · 4,000 Hz` / `Off · Configured at 4,000 Hz`.
    private var stateLabel: String {
        guard audioState.activeProfile(in: profileStore) != nil else { return "—" }
        return notchEnabled ? "On · \(frequencyLabel)"
                            : "Off · Configured at \(frequencyLabel)"
    }

    /// The left ear's frequency is the representative value. Adds an "L/R"
    /// split when the two ears differ (separate-notch mode with distinct
    /// values) so the readout doesn't silently lie about a divergence.
    private var frequencyLabel: String {
        guard let profile = audioState.activeProfile(in: profileStore) else { return "—" }
        let lFreq = Int(profile.leftNotch.frequencyHz)
        let rFreq = Int(profile.rightNotch.frequencyHz)
        if profile.separateNotch && lFreq != rFreq {
            return "\(lFreq.formatted()) / \(rFreq.formatted()) Hz"
        }
        return "\(lFreq.formatted()) Hz"
    }

    /// Writes both ears in lockstep regardless of `separateNotch` — the
    /// popover is for "turn it on" / "turn it off", not per-ear management.
    /// Frequency, depth, and width are untouched, so flipping back on restores
    /// exactly what was configured.
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
