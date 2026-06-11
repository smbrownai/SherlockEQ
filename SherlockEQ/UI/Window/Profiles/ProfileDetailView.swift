import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Editor panel for one `HearingProfile`. All edits route through
/// `ProfileStore.save(_:)`. Plain scrolling layout instead of `Form` so we get
/// predictable rendering inside the main window's split view.
struct ProfileDetailView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var autoEQRemote: AutoEQRemoteService
    @EnvironmentObject private var autoEQSavedProfiles: AutoEQSavedProfilesStore

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
                    }
                    .disabled(profile.isBuiltIn)
                    // Headphone correction lives OUTSIDE the built-in
                    // disable group: the search + saved-list panel
                    // browses and imports to global AppStorage state,
                    // not to the profile itself, so it must stay
                    // tappable even when the active profile is locked.
                    // The writable parts inside (Apply, file-picker
                    // import, clear button) gate themselves on
                    // `profile.isBuiltIn` individually.
                    autoEQSection(profile)
                    Group {
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
            Text("When the system output switches to the linked device, SherlockEQ activates this profile automatically. Leave \"Any device\" to keep this profile manual.")
                .font(.callout)
                .foregroundStyle(.secondary)
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
        // CoreAudio's `AudioObjectGetPropertyDataSize` can block the
        // calling thread when the audio HAL is in a confused state
        // (stuck aggregate devices, disconnected USB DACs the system
        // still thinks are present, post-sleep wedge). Running the
        // enumeration on the main thread froze the whole app at
        // launch — Profile Detail's `.onAppear` fires before the
        // window is even visible, so a hang here means no UI at all.
        // Hop to a background queue, then publish the result on main.
        Task.detached(priority: .userInitiated) {
            let devices = CATapEngine.allOutputDevices()
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            await MainActor.run {
                self.availableDevices = devices
            }
        }
    }

    @ViewBuilder private func autoEQSection(_ profile: HearingProfile) -> some View {
        sectionHeader("Headphone correction", help: .headphoneCorrection)
        sectionBox {
            VStack(alignment: .leading, spacing: 14) {
                appliedAutoEQRow(profile)
                conflictBanner(for: profile)
                Divider()
                AutoEQSearchView { _ in
                    // Per spec: import does NOT auto-apply. The user
                    // activates the saved entry explicitly via the
                    // saved-list Apply button below.
                }
                AutoEQSavedProfilesList(profile: profile) { saved in
                    applySavedAutoEQ(saved, to: profile)
                }
                .disabled(profile.isBuiltIn)
                if profile.isBuiltIn {
                    builtInCorrectionHint
                }
                if !audioState.autoEQEnabled {
                    autoEQDisabledHint
                }
                if AutoEQLibrary.entries(in: audioState.autoEQLibraryFolder).isEmpty == false ||
                    profile.autoEQName == nil {
                    legacyImportRow(for: profile)
                        .disabled(profile.isBuiltIn)
                }
            }
        }
    }

    /// Top-of-section summary of what's currently applied to this
    /// profile. Source of truth is `profile.autoEQ{Name,Bands,
    /// PreampDB}` — the saved-list "Apply" action writes through
    /// these fields, and the existing file-picker import path
    /// (`legacyImportRow`) still works for offline or curated-folder
    /// flows.
    @ViewBuilder
    private func appliedAutoEQRow(_ profile: HearingProfile) -> some View {
        if let name = profile.autoEQName, let bands = profile.autoEQBands {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Applied: \(name)").font(.callout.weight(.medium))
                    let preamp = profile.autoEQPreampDB ?? 0
                    Text("\(bands.count) bands · preamp \(String(format: "%+.1f", preamp)) dB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("On", isOn: Binding(
                    get: { audioState.autoEQEnabled },
                    set: { audioState.autoEQEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Bypass the AutoEQ stage without losing the loaded correction")
                Button(role: .destructive) { clearAutoEQ(on: profile) } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove headphone correction")
                .disabled(profile.isBuiltIn)
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: "headphones")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No correction applied").font(.callout)
                    Text("Search the AutoEQ catalog below, or import a local .txt file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    /// Advisory warning when an active AutoEQ filter boosts within
    /// ±1/3 octave of the tinnitus notch. Pure-function detector lives
    /// in `AutoEQConflictDetector`; this view just surfaces results
    /// and offers the spec's two action buttons.
    @ViewBuilder
    private func conflictBanner(for profile: HearingProfile) -> some View {
        let conflicts: [AutoEQConflictDetector.Conflict] = {
            guard audioState.autoEQEnabled, audioState.notchFilterEnabled else { return [] }
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
                    // "Show me" and "Adjust notch depth" both navigate
                    // away from this view; the actual jump-and-scroll
                    // hooks land with the Equalizer / Tinnitus Notch
                    // routing in a follow-up. For now they're inert
                    // affordances so the banner reads as designed and
                    // the wire-up is one selection-change away.
                }
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.12))
            )
        }
    }

    @ViewBuilder
    private var autoEQDisabledHint: some View {
        Label("AutoEQ stage is currently bypassed (toggle is off).", systemImage: "speaker.slash")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Search + importing to the saved list works on a built-in
    /// profile (those operations write to global AppStorage, not the
    /// locked profile), but actually applying a correction does not.
    /// Surface that so users aren't confused when Apply is greyed out
    /// after a successful import.
    @ViewBuilder
    private var builtInCorrectionHint: some View {
        Label(
            "Search and importing work here, but Apply is disabled on built-in profiles. Duplicate the profile above to apply a correction.",
            systemImage: "lock"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// File-picker / library-folder import path. Kept because users
    /// who curate a local folder of AutoEQ exports (Crinacle compares,
    /// custom-tuned files) still want the one-tap "From file…"
    /// affordance the remote catalog can't replace.
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
            profileStore: profileStore
        )
        if !ok {
            // Cache missing — re-fetch then re-apply on success.
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
                        profileStore: profileStore
                    )
                }
            }
        }
    }

    /// "Import…" / "Replace…" — a plain button when there's no library,
    /// or a Menu listing each `.txt` in the configured AutoEQ folder
    /// plus a "From file…" escape hatch. The library entries shortcut
    /// the NSOpenPanel for users who curate a folder of corrections.
    @ViewBuilder private func autoEQImportControl(for profile: HearingProfile, label: String) -> some View {
        let entries = AutoEQLibrary.entries(in: audioState.autoEQLibraryFolder)
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

    @ViewBuilder private func tuningSection(_ profile: HearingProfile) -> some View {
        sectionHeader("Tuning")
        sectionBox {
            eqModeRow(profile)
            Divider()
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
            Divider()
            separateChannelsRow(profile)
        }
    }

    /// EQ mode picker: which lens this profile uses on the Equalizer
    /// screen. The four modes are storage views onto one underlying
    /// band array — switching never deletes data, it only changes
    /// which slice is editable. A profile picks the way its owner
    /// wants to think about EQ; Expert is the "I want everything" mode.
    @ViewBuilder private func eqModeRow(_ profile: HearingProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("EQ mode")
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                Picker("", selection: Binding(
                    get: { profile.eqMode },
                    set: { v in update(profile) { $0.eqMode = v } }
                )) {
                    ForEach(EQMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
                // Belt-and-braces: the parent `Group { ... }
                // .disabled(profile.isBuiltIn)` higher up *should*
                // propagate to this picker too, but `.pickerStyle(.menu)`
                // has a SwiftUI quirk where the environment-level
                // disabled state doesn't reliably grey + block the
                // popup. Mark it explicitly here so built-in profiles
                // stay genuinely read-only.
                .disabled(profile.isBuiltIn)
                Spacer()
            }
            Text(profile.eqMode.tagline)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Per-profile UI toggle: when on, every EQ tab (Simple, Speech,
    /// Advanced, Expert) exposes per-ear sliders / band lists for
    /// fine-tuning. When off (default), one column drives both ears.
    /// Toggling never mutates band data — the profile's leftEar /
    /// rightEar arrays stay as they are; only future edits in the
    /// chosen mode propagate to one or both ears. The Audiogram screen
    /// is always per-ear regardless of this setting.
    @ViewBuilder private func separateChannelsRow(_ profile: HearingProfile) -> some View {
        // Compare by audio behaviour, not by band identity. EQBand
        // carries a UUID that's generated fresh on construction —
        // Simple/Speech/Advanced mint independent bands per ear via
        // EQBandLookup, so the raw `==` is almost always false even
        // when both ears describe identical filters. See
        // `Array<EQBand>.audiblyEquivalent(to:)`.
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
                        .help("This profile has different bands on each ear, but EQ tabs are in linked mode. Linked-mode edits will collapse the difference on bands you touch; untouched bands stay asymmetric.")
                }
            }
            Text(profile.separateChannels
                 ? "EQ tabs show per-ear sliders. Edits affect only the ear you touch."
                 : "EQ tabs show a single set of sliders. Edits apply to both ears.")
                .font(.callout)
                .foregroundStyle(.secondary)
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
                .font(.callout)
                .foregroundStyle(.secondary)
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

    private func sectionHeader(_ title: String, help: HelpTopic? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            if let help {
                HelpContextButton(help, label: title.lowercased())
            }
        }
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
            // Surfaced via ProfileStore.lastError (DebugView); built-in stays as-is.
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
        update(profile) {
            $0.autoEQName = name
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
