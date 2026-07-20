import SwiftUI

/// App-wide settings. Everyday preferences (General, Appearance, Keyboard)
/// stay open; professional DSP configuration (master gain + peak limiter)
/// lives under a collapsed **Advanced Audio** group, and file locations under
/// **Files & data**, so the page reads as preferences first, engineering
/// second.
struct SettingsView: View {
    /// Cached count of the AutoEQ library folder — enumerated off-main per
    /// folder change instead of inside the body (perf review M1; a real
    /// AutoEQ checkout is thousands of files).
    @State private var autoEQLibraryCount: Int = 0
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var profileStore: ProfileStore
    @State private var acknowledgmentsShown = false
    @State private var relocationAlert: RelocationPrompt?

    @State private var showGeneral = true
    @State private var showAppearance = true
    @State private var showKeyboard = true
    @State private var showAdvancedAudio = false
    @State private var showFiles = false
    @State private var showDiagnostics = false
    @State private var showAbout = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // No in-page "Settings" hero — the window title bar already
                // names the screen; a second copy was pure duplication.
                group("General", systemImage: "switch.2", isExpanded: $showGeneral) {
                    generalContent
                }
                group("Appearance", systemImage: "paintpalette", isExpanded: $showAppearance) {
                    appearanceContent
                }
                group("Keyboard", systemImage: "keyboard", isExpanded: $showKeyboard) {
                    keyboardContent
                }
                group("Advanced Audio", systemImage: "waveform.badge.exclamationmark", isExpanded: $showAdvancedAudio) {
                    advancedAudioContent
                }
                group("Data & Profiles", systemImage: "externaldrive", isExpanded: $showFiles) {
                    filesContent
                }
                group("Diagnostics", systemImage: "stethoscope", isExpanded: $showDiagnostics) {
                    diagnosticsContent
                }
                aboutSection
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $acknowledgmentsShown) {
            AcknowledgmentsView()
        }
        .alert(item: $relocationAlert) { prompt in
            Alert(
                title: Text("Use \(prompt.url.lastPathComponent) for profiles?"),
                message: Text("Existing profiles can either move with you to the new folder, or stay at the current location while the store switches to whatever's already in the new one."),
                primaryButton: .default(Text("Move existing")) {
                    performRelocate(to: prompt.url, moveExisting: true)
                },
                secondaryButton: .default(Text("Switch only")) {
                    performRelocate(to: prompt.url, moveExisting: false)
                }
            )
        }
        // Enumerate the AutoEQ library off-main, once per folder change,
        // instead of inside the body (perf review M1).
        .task(id: audioState.autoEQPreferences.libraryFolder) {
            let folder = audioState.autoEQPreferences.libraryFolder
            autoEQLibraryCount = await Task.detached {
                AutoEQLibrary.entries(in: folder).count
            }.value
        }
    }

    private struct RelocationPrompt: Identifiable {
        let url: URL
        var id: URL { url }
    }

    // MARK: - General

    @ViewBuilder private var generalContent: some View {
        Toggle("Launch at login", isOn: $preferences.launchAtLoginEnabled)
            .toggleStyle(.switch)
            .controlSize(.small)
        caption("Start SherlockEQ in the menu bar when you log in. Revoke it in System Settings → General → Login Items.")
        Divider()
        Toggle("Hide from Dock when window is closed", isOn: $preferences.hideFromDockEnabled)
            .toggleStyle(.switch)
            .controlSize(.small)
        caption("Keep running in the menu bar with no Dock icon after you close the window. Turn off if the menu bar fails to redraw on reopen.")
    }

    // MARK: - Appearance

    @ViewBuilder private var appearanceContent: some View {
        colorRow(label: "Left ear", binding: $preferences.leftEarColor, defaultColor: AppPreferences.defaultLeftEarColor)
        Divider()
        colorRow(label: "Right ear", binding: $preferences.rightEarColor, defaultColor: AppPreferences.defaultRightEarColor)
        caption("Colors for the left/right curves, audiogram thresholds, and EQ sliders.")
        Divider()
        Toggle("Show the EQ curve and quick tone adjustments in the menu-bar popover",
               isOn: $preferences.showPopoverEQCurve)
            .toggleStyle(.switch)
            .controlSize(.small)
        caption("A small read-only view of what your EQ is doing right now, with Bass, Mids, and Treble buttons that nudge the curve. Turn it off for a shorter popover — detailed editing always happens on the Equalizer screen.")
    }

    private func colorRow(label: String, binding: Binding<Color>, defaultColor: Color) -> some View {
        let isDefault = binding.wrappedValue.hexString == defaultColor.hexString
        return HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(minWidth: 120, alignment: .leading).layoutPriority(1)
            ColorPicker("", selection: binding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44)
            // Hex value hidden — the swatch/well is the editor; the raw code
            // is engineering noise on the everyday Appearance row.
            Spacer()
            Button {
                binding.wrappedValue = defaultColor
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Reset \(label.lowercased()) color to default")
            .disabled(isDefault)
            .opacity(isDefault ? 0.35 : 1)
        }
    }

    // MARK: - Keyboard (Reference Mode shortcut)

    @ViewBuilder private var keyboardContent: some View {
        Toggle("Global ⌘⇧B toggles Reference Mode", isOn: $preferences.globalReferenceShortcutEnabled)
            .toggleStyle(.switch)
            .controlSize(.small)
        caption("Reference Mode temporarily bypasses all processing so you hear the source unchanged. This makes ⌘⇧B work even when SherlockEQ is in the background; the ⌘B menu item always works when the window is key. Off by default — global shortcuts can collide with other apps.")
    }

    // MARK: - Advanced Audio (master gain + peak limiter)

    @ViewBuilder private var advancedAudioContent: some View {
        masterGainRow
        // Scope note: this is the single app-wide output gain, the same value
        // shown on the monitor panel — not a per-profile control.
        caption("App-wide output gain — the same control shown on the monitor panel. Applied after the limiter, so boosts up to +12 dB stay safe.")
        Divider()
        Text("Peak limiter")
            .font(.subheadline.weight(.medium))
        limiterParamRow(label: "Attack", value: audioState.engineParameters.limiterAttackMs,
                        range: 1.0...30.0, defaultValue: 12.0, format: { String(format: "%.1f ms", $0) },
                        set: { audioState.engineParameters.limiterAttackMs = $0 })
        limiterParamRow(label: "Decay", value: audioState.engineParameters.limiterDecayMs,
                        range: 1.0...60.0, defaultValue: 24.0, format: { String(format: "%.1f ms", $0) },
                        set: { audioState.engineParameters.limiterDecayMs = $0 })
        limiterParamRow(label: "Pre-gain", value: audioState.engineParameters.limiterPreGainDB,
                        range: -40...40, defaultValue: 0, format: { String(format: "%+.1f dB", $0) },
                        set: { audioState.engineParameters.limiterPreGainDB = $0 })
        caption("Shorter attack catches transients but adds distortion; longer decay smooths sustained signals but can pump; pre-gain pushes harder into the limiter. Defaults suit most listening.")
    }

    private var masterGainRow: some View {
        let isZero = abs(audioState.engineParameters.masterGainDB) < 0.05
        return HStack {
            HStack(spacing: 6) {
                Text("Master gain")
                    .foregroundStyle(.secondary)
                ScopeBadge(scope: .app)
            }
            .frame(minWidth: 150, alignment: .leading).layoutPriority(1)
            Slider(
                value: Binding(
                    get: { audioState.engineParameters.masterGainDB },
                    set: { audioState.engineParameters.masterGainDB = $0 }
                ),
                in: -60...12
            )
            .controlSize(.small)
            Text(gainLabel(audioState.engineParameters.masterGainDB))
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
                .frame(width: 72, alignment: .trailing)
            Button {
                audioState.engineParameters.masterGainDB = 0
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Reset master gain to 0 dB")
            .disabled(isZero)
            .opacity(isZero ? 0.35 : 1)
        }
    }

    private func gainLabel(_ db: Double) -> String {
        if db <= -59.9 { return "Muted" }
        if abs(db) < 0.05 { return "0.0 dB" }
        return String(format: "%+.1f dB", db)
    }

    private func limiterParamRow(
        label: String,
        value: Double,
        range: ClosedRange<Double>,
        defaultValue: Double,
        format: @escaping (Double) -> String,
        set: @escaping (Double) -> Void
    ) -> some View {
        let isDefault = abs(value - defaultValue) < 0.05
        return HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(minWidth: 120, alignment: .leading).layoutPriority(1)
            Slider(value: Binding(get: { value }, set: set), in: range)
                .controlSize(.small)
            Text(format(value))
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
                .frame(width: 72, alignment: .trailing)
            Button {
                set(defaultValue)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Reset \(label.lowercased()) to default")
            .disabled(isDefault)
            .opacity(isDefault ? 0.35 : 1)
        }
    }

    // MARK: - Files and data (profiles folder + AutoEQ library)

    @ViewBuilder private var filesContent: some View {
        // Profiles folder.
        HStack(spacing: 10) {
            Image(systemName: "tray.full").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(profileStore.directory.path)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(profileStore.directory.standardizedFileURL == ProfileStore.defaultDirectory().standardizedFileURL
                     ? "Profiles folder · Default (Application Support)"
                     : "Profiles folder · Custom location")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose…") { chooseProfilesFolder() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            if profileStore.directory.standardizedFileURL != ProfileStore.defaultDirectory().standardizedFileURL {
                Button("Reset") {
                    relocationAlert = RelocationPrompt(url: ProfileStore.defaultDirectory())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        caption("Point this at iCloud Drive / Dropbox / an external disk to back up or sync your profiles.")

        Divider()

        // AutoEQ library folder — a global convenience shared by every
        // profile's headphone-correction picker, so it lives with the other
        // file locations rather than inside one profile.
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                if let folder = audioState.autoEQPreferences.libraryFolder {
                    Text(folder.path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    let count = autoEQLibraryCount
                    Text("Headphone correction library · \(count) .txt file\(count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Headphone correction library · none set")
                        .font(.callout)
                    Text("Each profile's headphone picker falls back to a file picker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Choose…") { chooseAutoEQLibrary() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            if audioState.autoEQPreferences.libraryFolder != nil {
                Button(role: .destructive) { audioState.autoEQPreferences.libraryFolder = nil } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Clear library folder")
            }
        }
        caption("A folder of AutoEQ .txt files (one per headphone) that every profile's headphone picker can list by name.")
    }

    private func chooseAutoEQLibrary() {
        let panel = NSOpenPanel()
        panel.title = "Choose AutoEQ library folder"
        panel.prompt = "Use folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let current = audioState.autoEQPreferences.libraryFolder {
            panel.directoryURL = current
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        audioState.autoEQPreferences.libraryFolder = url
    }

    private func chooseProfilesFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose profiles folder"
        panel.prompt = "Use folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = profileStore.directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        relocationAlert = RelocationPrompt(url: url)
    }

    private func performRelocate(to url: URL, moveExisting: Bool) {
        do {
            try profileStore.relocate(to: url, moveExisting: moveExisting)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't switch profiles folder"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Diagnostics

    @ViewBuilder private var diagnosticsContent: some View {
        Toggle("Show Debug in sidebar", isOn: $preferences.showDebugInSidebar)
            .toggleStyle(.switch)
            .controlSize(.small)
        caption("Adds a Debug entry with diagnostic counters and test controls. Off by default.")
        Divider()
        Toggle("Show metadata on profiles", isOn: $preferences.showProfileMetadata)
            .toggleStyle(.switch)
            .controlSize(.small)
        caption("Shows created/modified timestamps and the unique ID on each profile's detail page.")
    }

    // MARK: - About

    private var aboutSection: some View {
        group("About", systemImage: "info.circle", isExpanded: $showAbout) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Acknowledgments").font(.callout.weight(.medium))
                    Text("Science, software, and prior art behind SherlockEQ.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("View…") { acknowledgmentsShown = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Building blocks

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

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

}
