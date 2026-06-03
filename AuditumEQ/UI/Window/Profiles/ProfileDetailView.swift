import SwiftUI

/// Editor panel for one `HearingProfile`. All edits route through
/// `ProfileStore.save(_:)`. Plain scrolling layout instead of `Form` so we get
/// predictable rendering inside the main window's split view.
struct ProfileDetailView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var audioState: AudioState

    let profileID: UUID

    private static let availableSymbols: [String] = [
        "person.fill",
        "ear",
        "headphones",
        "airpodspro",
        "speaker.wave.2.fill",
        "music.note",
        "waveform.badge.mic",
        "moon.fill",
        "sun.max.fill",
        "briefcase.fill",
        "house.fill",
        "figure.walk",
    ]

    var body: some View {
        if let profile = profile {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerBlock(profile)
                    identitySection(profile)
                    deviceSection(profile)
                    tuningSection(profile)
                    safetySection(profile)
                    metadataSection(profile)
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(profile.name)
        } else {
            ContentUnavailableView(
                "No profile selected",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text("Pick one from the list.")
            )
        }
    }

    // MARK: - Sections

    @ViewBuilder private func headerBlock(_ profile: HearingProfile) -> some View {
        HStack(spacing: 14) {
            Image(systemName: profile.symbol)
                .font(.system(size: 32))
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.title2.weight(.semibold))
                Text(audioState.activeProfileID == profile.id ? "Active" : "Inactive")
                    .font(.caption)
                    .foregroundStyle(audioState.activeProfileID == profile.id ? .green : .secondary)
            }
            Spacer()
            Button {
                audioState.activeProfileID = profile.id
            } label: {
                Label(
                    audioState.activeProfileID == profile.id ? "Active" : "Make Active",
                    systemImage: audioState.activeProfileID == profile.id ? "checkmark.circle.fill" : "circle"
                )
            }
            .buttonStyle(.bordered)
            .disabled(audioState.activeProfileID == profile.id)
        }
    }

    @ViewBuilder private func identitySection(_ profile: HearingProfile) -> some View {
        sectionHeader("Identity")
        sectionBox {
            row("Name") {
                TextField("", text: bindingForName(profile))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
            }
            Divider()
            row("Icon") {
                symbolPicker(profile)
            }
        }
    }

    @ViewBuilder private func deviceSection(_ profile: HearingProfile) -> some View {
        sectionHeader("Output device")
        sectionBox {
            row("Linked device") {
                Text(profile.linkedDeviceUID ?? "Not linked")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            Divider()
            Text("Auto-switching to a specific output device lands in Session 17.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder private func tuningSection(_ profile: HearingProfile) -> some View {
        sectionHeader("Tuning")
        sectionBox {
            sliderRow(
                "Compensation",
                value: profile.compensationFactor,
                range: 0.25...1.0,
                format: { String(format: "%.0f%%", $0 * 100) },
                set: { v in update(profile) { $0.compensationFactor = v } }
            )
            Divider()
            sliderRow(
                "Global trim",
                value: profile.globalTrimDB,
                range: -12...12,
                format: { String(format: "%+.1f dB", $0) },
                set: { v in update(profile) { $0.globalTrimDB = v } }
            )
            Divider()
            balanceRow(profile)
        }
    }

    /// Stereo balance: linear L↔R pan. Double-click the slider to recenter.
    @ViewBuilder private func balanceRow(_ profile: HearingProfile) -> some View {
        HStack {
            Text("Balance")
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Slider(
                value: Binding(
                    get: { profile.balance },
                    set: { v in update(profile) { $0.balance = v } }
                ),
                in: -1...1
            )
            .controlSize(.small)
            .onTapGesture(count: 2) {
                update(profile) { $0.balance = 0 }
            }
            Text(balanceLabel(profile.balance))
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
                .frame(width: 72, alignment: .trailing)
        }
    }

    private func balanceLabel(_ b: Double) -> String {
        if abs(b) < 0.005 { return "Center" }
        let pct = Int((abs(b) * 100).rounded())
        return b < 0 ? "L \(pct)%" : "R \(pct)%"
    }

    @ViewBuilder private func safetySection(_ profile: HearingProfile) -> some View {
        sectionHeader("Safe listening")
        sectionBox {
            sliderRow(
                "Ceiling",
                value: profile.safeListeningCeilingDB,
                range: 70...100,
                format: { String(format: "%.0f dBA", $0) },
                set: { v in update(profile) { $0.safeListeningCeilingDB = v } }
            )
            Divider()
            Text("NIOSH recommends 85 dBA over 8 hours; lower values shorten the safe daily duration.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder private func metadataSection(_ profile: HearingProfile) -> some View {
        sectionHeader("Metadata")
        sectionBox {
            metaRow("Created", text: profile.createdAt.formatted(date: .abbreviated, time: .shortened))
            Divider()
            metaRow("Modified", text: profile.modifiedAt.formatted(date: .abbreviated, time: .shortened))
            Divider()
            metaRow("ID", text: profile.id.uuidString)
        }
    }

    // MARK: - Building blocks

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func sectionBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    @ViewBuilder
    private func row<Right: View>(_ label: String, @ViewBuilder right: () -> Right) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            right()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func sliderRow(
        _ label: String,
        value: Double,
        range: ClosedRange<Double>,
        format: @escaping (Double) -> String,
        set: @escaping (Double) -> Void
    ) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range)
                .controlSize(.small)
            Text(format(value))
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
                .frame(width: 72, alignment: .trailing)
        }
    }

    private func metaRow(_ label: String, text: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(text)
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func symbolPicker(_ profile: HearingProfile) -> some View {
        Menu {
            ForEach(Self.availableSymbols, id: \.self) { symbol in
                Button {
                    update(profile) { $0.symbol = symbol }
                } label: {
                    Label(symbol, systemImage: symbol)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: profile.symbol)
                    .font(.system(size: 14))
                Text(profile.symbol)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.3))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Plumbing

    private var profile: HearingProfile? {
        profileStore.profiles.first(where: { $0.id == profileID })
    }

    private func bindingForName(_ profile: HearingProfile) -> Binding<String> {
        Binding(
            get: { profile.name },
            set: { newValue in update(profile) { $0.name = newValue } }
        )
    }

    private func update(_ profile: HearingProfile, _ mutate: (inout HearingProfile) -> Void) {
        var copy = profile
        mutate(&copy)
        try? profileStore.save(copy)
    }
}
