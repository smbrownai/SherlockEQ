import SwiftUI

/// Copy the active profile's audiogram (per-ear dB HL thresholds) onto one or
/// more other profiles in a single pass.
///
/// Routes through `AudiogramInterchange` — the same HealthKit-shaped exchange
/// type the iOS companion maps an `HKAudiogramSample` into — so every target
/// receives the identical measured thresholds and has its NAL-R correction
/// layer recomputed via `HearingProfile.applyingAudiogram`. Each target keeps
/// its own EQ, tinnitus notch, and compensation strength; only the thresholds
/// and the derived `correctionBands` change. The source profile is excluded
/// (it already has this audiogram).
struct ApplyAudiogramSheet: View {
    /// The active profile whose audiogram is being copied out.
    let source: HearingProfile

    @EnvironmentObject private var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<UUID> = []
    /// Names of the profiles written on a successful apply — non-nil flips the
    /// sheet into its confirmation state.
    @State private var appliedNames: [String]?

    /// Every profile except the source — these are the copy targets.
    private var candidates: [HearingProfile] {
        profileStore.profiles.filter { $0.id != source.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 460, height: 480)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Apply Audiogram to Other Profiles")
                .font(.headline)
            Text("Copies \(source.name)'s hearing thresholds onto the profiles you choose and recomputes their hearing adjustment. Their EQ, tinnitus notch, and compensation strength are left as they are.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        if let appliedNames {
            confirmation(appliedNames)
        } else if candidates.isEmpty {
            ContentUnavailableView(
                "No other profiles",
                systemImage: "person.2.slash",
                description: Text("Create another profile first, then copy this audiogram onto it.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(candidates) { profile in
                    row(profile)
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ profile: HearingProfile) -> some View {
        Button {
            toggle(profile.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected.contains(profile.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.contains(profile.id) ? Color.accentColor : .secondary)
                Text(profile.name)
                if profile.isBuiltIn {
                    Text("Built-in")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func confirmation(_ names: [String]) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text(names.count == 1 ? "Applied to 1 profile" : "Applied to \(names.count) profiles")
                .font(.headline)
            Text(names.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder private var footer: some View {
        if appliedNames != nil {
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        } else {
            HStack {
                if !candidates.isEmpty {
                    Button(allSelected ? "Deselect All" : "Select All") { toggleAll() }
                        .buttonStyle(.link)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
            .padding(16)
        }
    }

    // MARK: - Actions

    private var allSelected: Bool {
        !candidates.isEmpty && selected.count == candidates.count
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func toggleAll() {
        if allSelected { selected.removeAll() } else { selected = Set(candidates.map(\.id)) }
    }

    private func apply() {
        let doc = AudiogramInterchange.from(
            left: source.leftEar.thresholds,
            right: source.rightEar.thresholds,
            source: "Copied from \(source.name)"
        )
        let now = Date()
        var done: [String] = []
        // Iterate `candidates` (not `selected`) so the write order is stable and
        // we only ever touch profiles still present in the store.
        for profile in candidates where selected.contains(profile.id) {
            do {
                try profileStore.save(
                    profile.applyingAudiogram(doc, modifiedAt: now),
                    actionName: "Apply audiogram to \(profile.name)"
                )
                done.append(profile.name)
            } catch {
                // ProfileStore.lastError → NoticeCenter banner surfaces the
                // failure; stop here so we don't pile on more errors.
                break
            }
        }
        if done.isEmpty { dismiss() } else { appliedNames = done }
    }
}
