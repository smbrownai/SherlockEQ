import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Editor panel for one `HearingProfile`. All edits route through
/// `ProfileStore.save(_:)`. The long form is broken into a scannable
/// **summary** plus collapsible groups (Identity, Device & headphones,
/// Hearing personalization, Sound tuning, Safety) so the most cognitively
/// demanding screen in the app reads one section at a time. Specialist knobs
/// (Compensation, Global trim, separate-ear) live under **Advanced tuning**.
struct ProfileDetailView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var autoEQRemote: AutoEQRemoteService
    @EnvironmentObject private var autoEQSavedProfiles: AutoEQSavedProfilesStore

    let profileID: UUID
    var onDuplicatedToCopy: ((HearingProfile) -> Void)? = nil

    // Group expansion — grouped-but-visible by default; the user can collapse
    // any section. "Advanced tuning" is the only thing hidden by default.
    @State private var showIdentity = true
    @State private var showDevice = true
    @State private var showHearing = true
    @State private var showTuning = true
    @State private var showSafety = true
    @State private var showAdvancedTuning = false
    @State private var showMetadata = false
    /// The "nothing applied" headphone state stays compact until the user
    /// chooses to look for their headphones.
    @State private var showHeadphoneSearch = false

    @State private var availableDevices: [CATapEngine.OutputDevice] = []

    private struct ProfileIcon: Hashable {
        let symbol: String
        let name: String
    }

    private static let availableSymbols: [ProfileIcon] = [
        .init(symbol: "person.fill",          name: "Person"),
        .init(symbol: "ear",                  name: "Ear"),
        .init(symbol: "headphones",           name: "Headphones"),
        .init(symbol: "airpodspro",           name: "AirPods Pro"),
        .init(symbol: "speaker.wave.2.fill",  name: "Speaker"),
        .init(symbol: "music.note",           name: "Music"),
        .init(symbol: "waveform.badge.mic",   name: "Voice"),
        .init(symbol: "moon.fill",            name: "Night"),
        .init(symbol: "sun.max.fill",         name: "Day"),
        .init(symbol: "briefcase.fill",       name: "Work"),
        .init(symbol: "house.fill",           name: "Home"),
        .init(symbol: "figure.walk",          name: "On the Go"),
    ]

    private static func iconName(for symbol: String) -> String {
        availableSymbols.first { $0.symbol == symbol }?.name ?? symbol
    }

    private var isActive: Bool { audioState.activeProfileID == profileID }

    var body: some View {
        if let profile = profile {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerBlock(profile)
                    if profile.isBuiltIn {
                        FactoryPresetBanner(
                            profileName: profile.name,
                            canReset: profileStore.differsFromFactory(profile),
                            onReset: { profileStore.resetProfileToFactory(profile.id) },
                            onDuplicate: { duplicateAndHandoff(profile) }
                        )
                    }
                    summaryCard(profile)

                    group("Identity", systemImage: "person.text.rectangle", isExpanded: $showIdentity) {
                        identityContent(profile)
                    }
                    group("Device and headphones", systemImage: "headphones", isExpanded: $showDevice) {
                        deviceContent(profile)
                        Divider()
                        headphoneContent(profile)
                    }
                    group("Hearing personalization", systemImage: "ear", isExpanded: $showHearing) {
                        hearingContent(profile)
                    }
                    group("Sound tuning", systemImage: "slider.horizontal.3", isExpanded: $showTuning) {
                        soundTuningContent(profile)
                    }
                    group("Safety", systemImage: "shield.lefthalf.filled", isExpanded: $showSafety) {
                        safetyContent(profile)
                    }
                    if audioState.preferences.showProfileMetadata {
                        group("Metadata", systemImage: "info.circle", isExpanded: $showMetadata) {
                            metadataContent(profile)
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(profile.name)
            .onAppear { refreshDeviceList() }
        } else {
            ContentUnavailableView(
                "No profile selected",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text("Pick one from the list.")
            )
        }
    }

    // MARK: - Header (selected vs. active, made explicit)

    @ViewBuilder private func headerBlock(_ profile: HearingProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Image(systemName: profile.symbol)
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).font(.title2.weight(.semibold))
                    // "Editing" always applies (this is the selected profile);
                    // the green "Processing audio now" pill only shows when it's
                    // also the active profile. Two distinct meanings, two labels.
                    HStack(spacing: 8) {
                        Text("Editing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if isActive {
                            Label("Processing audio now", systemImage: "waveform")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.green.opacity(0.14)))
                        }
                    }
                }
                Spacer()
                Button {
                    audioState.activeProfileID = profile.id
                } label: {
                    Label(isActive ? "Active" : "Make Active",
                          systemImage: isActive ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.bordered)
                .disabled(isActive)
            }
            if let description = profile.presetDescription, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !profile.presetTags.isEmpty {
                TagChips(tags: profile.presetTags)
            }
        }
    }

    // MARK: - Summary card

    private func summaryCard(_ profile: HearingProfile) -> some View {
        let items: [(label: String, value: String, symbol: String)] = [
            ("Output device", deviceSummary(profile), "hifispeaker"),
            ("Headphone correction", profile.autoEQName ?? "None", "headphones"),
            ("Hearing profile", hearingSummary(profile), "ear"),
            ("EQ surface", profile.eqMode.label, "slider.horizontal.3"),
            ("Per-ear", profile.separateChannels ? "Separate L/R" : "Linked", "person.2"),
        ]
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 170), spacing: 10)],
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(items, id: \.label) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.symbol)
                        .foregroundStyle(.tint)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(item.value)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            }
        }
    }

    private func deviceSummary(_ profile: HearingProfile) -> String {
        guard let uid = profile.linkedDeviceUID else { return "Any device" }
        return availableDevices.first(where: { $0.uid == uid })?.name ?? "Linked (offline)"
    }

    private func hearingSummary(_ profile: HearingProfile) -> String {
        let hasAudiogram = !profile.leftEar.correctionBands.isEmpty || !profile.rightEar.correctionBands.isEmpty
        guard hasAudiogram else { return "No audiogram" }
        return profile.correctionMode == .adaptive ? "Audiogram · Adaptive" : "Audiogram · Steady"
    }

    // MARK: - Identity

    @ViewBuilder private func identityContent(_ profile: HearingProfile) -> some View {
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

    // MARK: - Device & headphones

    @ViewBuilder private func deviceContent(_ profile: HearingProfile) -> some View {
        row("Linked device") {
            deviceMenu(profile)
        }
        Text("When the system output switches to the linked device, SherlockEQ activates this profile automatically. Leave \"Any device\" to keep this profile manual.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
    }

    @ViewBuilder private func deviceMenu(_ profile: HearingProfile) -> some View {
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
        Task.detached(priority: .userInitiated) {
            let devices = CATapEngine.allOutputDevices()
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            await MainActor.run {
                self.availableDevices = devices
            }
        }
    }

    /// Headphone correction. Common state ("nothing applied") stays a single
    /// compact line + a "Find my headphones…" button; the search/library UI
    /// only appears once the user asks for it.
    @ViewBuilder private func headphoneContent(_ profile: HearingProfile) -> some View {
        HStack(spacing: 6) {
            Text("Headphone correction")
                .font(.subheadline.weight(.medium))
            HelpContextButton(.headphoneCorrection, label: "headphone correction")
        }

        if profile.autoEQName != nil {
            appliedAutoEQRow(profile)
            conflictBanner(for: profile)
            if !audioState.eqChain.autoEQEnabled { autoEQDisabledHint }
            managementDisclosure(profile)
        } else if showHeadphoneSearch {
            HStack {
                Text("Search the AutoEQ catalog, or import a local .txt file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { showHeadphoneSearch = false }
                    .controlSize(.small)
            }
            AutoEQSearchView { _ in }
            AutoEQSavedProfilesList(profile: profile) { saved in
                applySavedAutoEQ(saved, to: profile)
            }
            legacyImportRow(for: profile)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "headphones").foregroundStyle(.secondary)
                Text("None")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showHeadphoneSearch = true
                } label: {
                    Label("Find my headphones…", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    /// When a correction IS applied, the search/library lives behind a
    /// disclosure so the common "it's set, leave it" state stays compact.
    @ViewBuilder private func managementDisclosure(_ profile: HearingProfile) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                AutoEQSearchView { _ in }
                AutoEQSavedProfilesList(profile: profile) { saved in
                    applySavedAutoEQ(saved, to: profile)
                }
                legacyImportRow(for: profile)
            }
            .padding(.top, 8)
        } label: {
            Text("Change headphones")
                .font(.subheadline.weight(.medium))
        }
    }

    @ViewBuilder
    private func appliedAutoEQRow(_ profile: HearingProfile) -> some View {
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
                Toggle("On", isOn: Binding(
                    get: { audioState.eqChain.autoEQEnabled },
                    set: { audioState.eqChain.autoEQEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Bypass the AutoEQ stage without losing the loaded correction")
                Button(role: .destructive) { clearAutoEQ(on: profile) } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove headphone correction")
            }
        }
    }

    @ViewBuilder
    private func conflictBanner(for profile: HearingProfile) -> some View {
        let conflicts: [AutoEQConflictDetector.Conflict] = {
            guard audioState.eqChain.autoEQEnabled, audioState.eqChain.notchFilterEnabled else { return [] }
            return AutoEQConflictDetector.detect(in: profile)
        }()
        if !conflicts.isEmpty {
            let exact = conflicts.first(where: \.isExactMatch)
            let notchFreq = profile.leftNotch.enabled
                ? profile.leftNotch.frequencyHz
                : profile.rightNotch.frequencyHz
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    if let exact {
                        Text("An AutoEQ filter is centered exactly on your tinnitus frequency (\(Int(exact.band.frequencyHz)) Hz). Consider disabling AutoEQ correction at this frequency.")
                            .font(.callout)
                    } else {
                        Text("One or more AutoEQ filters boost near your tinnitus frequency (\(Int(notchFreq)) Hz). This may reduce notch therapy effectiveness.")
                            .font(.callout)
                    }
                    Text("Flagged \(conflicts.count) band\(conflicts.count == 1 ? "" : "s") within ±1/3 octave.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        }
    }

    @ViewBuilder
    private var autoEQDisabledHint: some View {
        Label("AutoEQ stage is currently bypassed (toggle is off).", systemImage: "speaker.slash")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func legacyImportRow(for profile: HearingProfile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text("Or import a local .txt file")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            autoEQImportControl(for: profile, label: profile.autoEQName == nil ? "Import…" : "Replace…")
        }
    }

    private func applySavedAutoEQ(_ saved: AutoEQSavedProfilesStore.SavedEntry, to profile: HearingProfile) {
        let ok = autoEQSavedProfiles.apply(
            path: saved.path,
            to: profile,
            service: autoEQRemote,
            profileStore: profileStore,
            deviceUID: audioState.tap.currentOutputDeviceUID,
            deviceName: audioState.tap.currentOutputDeviceName
        )
        if !ok {
            let entry = AutoEQIndexEntry(
                name: saved.name,
                path: saved.path,
                source: saved.source,
                type: saved.type
            )
            Task {
                if (try? await autoEQRemote.fetchProfile(for: entry)) != nil {
                    _ = autoEQSavedProfiles.apply(
                        path: saved.path,
                        to: profile,
                        service: autoEQRemote,
                        profileStore: profileStore,
                        deviceUID: audioState.tap.currentOutputDeviceUID,
                        deviceName: audioState.tap.currentOutputDeviceName
                    )
                }
            }
        }
    }

    @ViewBuilder private func autoEQImportControl(for profile: HearingProfile, label: String) -> some View {
        let entries = AutoEQLibrary.entries(in: audioState.autoEQPreferences.libraryFolder)
        if entries.isEmpty {
            Button(label) { importAutoEQ(into: profile) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        } else {
            Menu(label) {
                ForEach(entries) { entry in
                    Button(entry.name) { applyAutoEQ(at: entry.url, name: entry.name, to: profile) }
                }
                Divider()
                Button("From file…") { importAutoEQ(into: profile) }
            }
            .menuStyle(.borderedButton)
            .controlSize(.small)
            .fixedSize()
        }
    }

    // MARK: - Hearing personalization

    @ViewBuilder private func hearingContent(_ profile: HearingProfile) -> some View {
        let hasAudiogram = !profile.leftEar.correctionBands.isEmpty || !profile.rightEar.correctionBands.isEmpty
        HStack(spacing: 10) {
            Image(systemName: hasAudiogram ? "checkmark.seal.fill" : "ear")
                .foregroundStyle(hasAudiogram ? .green : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(hasAudiogram
                     ? (profile.correctionMode == .adaptive ? "Audiogram adjustment · Adaptive" : "Audiogram adjustment · Steady")
                     : "No audiogram yet")
                    .font(.callout.weight(.medium))
                Text(hasAudiogram
                     ? "Thresholds and adjustment style are edited on the Audiogram screen."
                     : "Enter thresholds or run the Listening Check to personalize your hearing adjustment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                audioState.pendingMainSection = .audiogram
            } label: {
                Label(hasAudiogram ? "Edit audiogram" : "Set up", systemImage: "waveform.path.ecg")
            }
            .controlSize(.small)
        }
    }

    // MARK: - Sound tuning (common visible; specialist under Advanced)

    @ViewBuilder private func soundTuningContent(_ profile: HearingProfile) -> some View {
        balanceRow(profile)

        DisclosureGroup(isExpanded: $showAdvancedTuning) {
            VStack(alignment: .leading, spacing: 12) {
                sliderRow(
                    "Compensation",
                    value: profile.compensationFactor,
                    range: 0.25...1.0,
                    format: { String(format: "%.0f%%", $0 * 100) },
                    set: { v in update(profile) { $0.compensationFactor = v } }
                )
                AcclimatizationChip(subject: profile, compact: true)
                sliderRow(
                    "Global trim",
                    value: profile.globalTrimDB,
                    range: -12...12,
                    format: { String(format: "%+.1f dB", $0) },
                    set: { v in update(profile) { $0.globalTrimDB = v } }
                )
                separateChannelsRow(profile)
            }
            .padding(.top, 8)
        } label: {
            Text("Advanced tuning")
                .font(.subheadline.weight(.medium))
        }
    }

    @ViewBuilder private func separateChannelsRow(_ profile: HearingProfile) -> some View {
        let asymmetric = !profile.leftEar.bands.audiblyEquivalent(to: profile.rightEar.bands)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Separate L + R")
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                Toggle("", isOn: Binding(
                    get: { profile.separateChannels },
                    set: { v in update(profile) { $0.separateChannels = v } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                Spacer()
                if asymmetric && !profile.separateChannels {
                    Label("L ≠ R", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .help("This profile has different bands on each ear, but the EQ is in linked mode. Linked-mode edits will collapse the difference on bands you touch; untouched bands stay asymmetric.")
                }
            }
            Text(profile.separateChannels
                 ? "The EQ shows per-ear sliders. Edits affect only the ear you touch."
                 : "The EQ shows a single set of sliders. Edits apply to both ears.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

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

    // MARK: - Safety

    @ViewBuilder private func safetyContent(_ profile: HearingProfile) -> some View {
        sliderRow(
            "Listening limit",
            value: profile.safeListeningCeilingDB,
            range: 70...100,
            format: { String(format: "%.0f dBA", $0) },
            set: { v in update(profile) { $0.safeListeningCeilingDB = v } }
        )
        Text("NIOSH recommends 85 dBA over 8 hours; lower values shorten the safe daily duration.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
    }

    // MARK: - Metadata

    @ViewBuilder private func metadataContent(_ profile: HearingProfile) -> some View {
        metaRow("Created", text: profile.createdAt.formatted(date: .abbreviated, time: .shortened))
        Divider()
        metaRow("Modified", text: profile.modifiedAt.formatted(date: .abbreviated, time: .shortened))
        Divider()
        metaRow("ID", text: profile.id.uuidString)
    }

    // MARK: - Group scaffold

    @ViewBuilder
    private func group<Content: View>(
        _ title: String,
        systemImage: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder _ content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
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
            ForEach(Self.availableSymbols, id: \.self) { icon in
                Button {
                    update(profile) { $0.symbol = icon.symbol }
                } label: {
                    Label(icon.name, systemImage: icon.symbol)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: profile.symbol)
                    .font(.system(size: 14))
                Text(Self.iconName(for: profile.symbol))
                    .font(.callout)
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

    private func duplicateAndHandoff(_ profile: HearingProfile) {
        var copy = profile.duplicated()
        copy.name = uniqueName(base: copy.name)
        do {
            try profileStore.save(copy)
            audioState.activeProfileID = copy.id
            onDuplicatedToCopy?(copy)
        } catch {
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
        applyAutoEQ(at: url, name: url.deletingPathExtension().lastPathComponent, to: profile)
    }

    private func applyAutoEQ(at url: URL, name: String, to profile: HearingProfile) {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let parsed = AutoEQParser.parse(text) else { return }
        let deviceUID = audioState.tap.currentOutputDeviceUID
        let deviceName = audioState.tap.currentOutputDeviceName
        update(profile) {
            $0.autoEQName = name
            $0.autoEQBands = parsed.bands
            $0.autoEQPreampDB = parsed.preampDB
            $0.autoEQDeviceUID = deviceUID
            $0.autoEQDeviceName = deviceUID == nil ? nil : deviceName
        }
    }

    private func clearAutoEQ(on profile: HearingProfile) {
        update(profile) {
            $0.autoEQName = nil
            $0.autoEQBands = nil
            $0.autoEQPreampDB = nil
            $0.autoEQDeviceUID = nil
            $0.autoEQDeviceName = nil
        }
        showHeadphoneSearch = false
    }
}
