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
                .frame(width: 100, alignment: .leading)

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

    private var notchEnabled: Bool {
        audioState.activeProfile(in: profileStore)?.notch.enabled ?? false
    }

    private var frequencyLabel: String {
        guard let profile = audioState.activeProfile(in: profileStore) else { return "—" }
        return "\(Int(profile.notch.frequencyHz).formatted()) Hz"
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { notchEnabled },
            set: { newValue in
                guard var p = audioState.activeProfile(in: profileStore) else { return }
                p.notch.enabled = newValue
                try? profileStore.save(p)
            }
        )
    }
}
