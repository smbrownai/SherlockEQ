import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Editor panel for one `HearingProfile`. All edits route through
/// `ProfileStore.save(_:)`. Plain scrolling layout instead of `Form` so we get
/// predictable rendering inside the main window's split view.
struct ProfileDetailView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var audioState: AudioState

    let profileID: UUID
    /// Optional hook the parent uses to follow up on a "Duplicate to
    /// customize" tap from the built-in banner — typically the parent
    /// updates its own selection to the new copy's ID.
    var onDuplicatedToCopy: ((HearingProfile) -> Void)? = nil

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
                    if profile.isBuiltIn {
                        BuiltInProfileBanner(profileName: profile.name) {
                            duplicateAndHandoff(profile)
                        }
                    }
                    Group {
                        identitySection(profile)
                        deviceSection(profile)
                        autoEQSection(profile)
                        tuningSection(profile)
                        safetySection(profile)
                    }
                    .disabled(profile.isBuiltIn)
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

    @State private var availableDevices: [CATapEngine.OutputDevice] = []

    @ViewBuilder private func deviceSection(_ profile: HearingProfile) -> some View {
        sectionHeader("Output device")
        sectionBox {
            row("Linked device") {
                deviceMenu(profile)
            }
            Divider()
            Text("When the system output switches to the linked device, AuditumEQ activates this profile automatically. Leave \"Any device\" to keep this profile manual.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 4)
        }
        .onAppear { refreshDeviceList() }
    }

    @ViewBuilder private func deviceMenu(_ profile: HearingProfile) -> some View {
        // If the profile is linked to a device that's not currently
        // connected (e.g. AirPods that aren't in range), surface that as a
        // stub entry so the user can still see and unlink it.
        let stubName: String? = {
            guard let uid = profile.linkedDeviceUID,
                  !availableDevices.contains(where: { $0.uid == uid }) else { return nil }
            return uid
        }()

        Menu {
            Button("Any device (manual)") {
                update(profile) { $0.linkedDeviceUID = nil }
            }
            if !availableDevices.isEmpty {
                Divider()
                ForEach(availableDevices) { dev in
                    Button {
                        update(profile) { $0.linkedDeviceUID = dev.uid }
                    } label: {
                        Label(dev.name, systemImage: profile.linkedDeviceUID == dev.uid ? "checkmark" : "")
                    }
                }
            }
            if let stubName {
                Divider()
                Button {
                    update(profile) { $0.linkedDeviceUID = nil }
                } label: {
                    Label("Disconnected: \(stubName)", systemImage: "exclamationmark.triangle")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: profile.linkedDeviceUID == nil ? "circle" : "headphones")
                Text(currentDeviceLabel(profile))
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

    private func currentDeviceLabel(_ profile: HearingProfile) -> String {
        guard let uid = profile.linkedDeviceUID else { return "Any device" }
        if let match = availableDevices.first(where: { $0.uid == uid }) {
            return match.name
        }
        return "Disconnected"
    }

    private func refreshDeviceList() {
        availableDevices = CATapEngine.allOutputDevices()
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder private func autoEQSection(_ profile: HearingProfile) -> some View {
        sectionHeader("Headphone correction")
        sectionBox {
            if let name = profile.autoEQName, let bands = profile.autoEQBands {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.callout.weight(.medium))
                        let preamp = profile.autoEQPreampDB ?? 0
                        Text("\(bands.count) bands · preamp \(String(format: "%+.1f", preamp)) dB")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Replace…") { importAutoEQ(into: profile) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button(role: .destructive) { clearAutoEQ(on: profile) } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove headphone correction")
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "headphones")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No correction loaded").font(.callout)
                        Text("Import an AutoEQ .txt file to correct for your headphones' frequency response.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Import…") { importAutoEQ(into: profile) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
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

    /// Stereo balance: linear L↔R pan. The recenter button next to the
    /// readout resets to 0 — a double-click on the slider doesn't work
    /// because Slider's own gesture eats the tap.
    @ViewBuilder private func balanceRow(_ profile: HearingProfile) -> some View {
        let centered = abs(profile.balance) < 0.005
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
            Text(balanceLabel(profile.balance))
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
                .frame(width: 72, alignment: .trailing)
            Button {
                update(profile) { $0.balance = 0 }
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Reset balance to center")
            .disabled(centered)
            .opacity(centered ? 0.35 : 1)
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

    /// Save a duplicate of the built-in, activate it, and let the parent
    /// follow up (typically by syncing its list selection).
    private func duplicateAndHandoff(_ profile: HearingProfile) {
        var copy = profile.duplicated()
        copy.name = uniqueName(base: copy.name)
        do {
            try profileStore.save(copy)
            audioState.activeProfileID = copy.id
            onDuplicatedToCopy?(copy)
        } catch {
            // Surfaced via ProfileStore.lastError; built-in stays as-is.
        }
    }

    private func uniqueName(base: String) -> String {
        let existing = Set(profileStore.profiles.map(\.name))
        if !existing.contains(base) { return base }
        var i = 2
        while existing.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    // MARK: - AutoEQ import / clear

    private func importAutoEQ(into profile: HearingProfile) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import AutoEQ correction"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let parsed = AutoEQParser.parse(text) else {
            return
        }
        update(profile) {
            $0.autoEQName = url.deletingPathExtension().lastPathComponent
            $0.autoEQBands = parsed.bands
            $0.autoEQPreampDB = parsed.preampDB
        }
    }

    private func clearAutoEQ(on profile: HearingProfile) {
        update(profile) {
            $0.autoEQName = nil
            $0.autoEQBands = nil
            $0.autoEQPreampDB = nil
        }
    }
}
