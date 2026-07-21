import SwiftUI

/// App-wide settings, as a responsive two-column card grid.
///
/// Every category used to be a full-width `DisclosureGroup`, which had two
/// problems: a settings row's control sat immediately after its label, so
/// nothing lined up down the page, and descriptions ran the full width of the
/// detail column with a lot of empty space to their right. Collapsing
/// *everything* also made ordinary preferences feel hidden — an accordion
/// suits specialised sections, not "Launch at login".
///
/// So: cards on a constrained measure, controls at the trailing edge, and
/// disclosure kept only for the two specialised categories (Advanced Audio,
/// Diagnostics) that genuinely benefit from being folded away.
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

    @State private var showAdvancedAudio = false

    @State private var showDiagnostics = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.cardSpacing) {
                // `.adaptive` does the responsive work without measuring the
                // window: two columns while the content width allows two
                // `cardMinWidth` cells, one when it doesn't. Row-major order
                // means each row is as tall as its taller card and no taller —
                // Appearance is allowed to outgrow Keyboard rather than
                // everything being padded to a common height.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: Self.cardMinWidth),
                                       spacing: Self.cardSpacing,
                                       alignment: .top)],
                    alignment: .leading,
                    spacing: Self.cardSpacing
                ) {
                    card("General", systemImage: "switch.2") { generalContent }
                    card("Appearance", systemImage: "paintpalette") { appearanceContent }
                    card("Keyboard", systemImage: "keyboard") { keyboardContent }
                    card("Data & Profiles", systemImage: "externaldrive") { filesContent }
                    disclosureCard("Advanced Audio",
                                   systemImage: "waveform.badge.exclamationmark",
                                   isExpanded: $showAdvancedAudio) { advancedAudioContent }
                    disclosureCard("Diagnostics",
                                   systemImage: "stethoscope",
                                   isExpanded: $showDiagnostics) { diagnosticsContent }
                }
                aboutCard
            }
            // Prose and controls want a measure, not the whole window.
            .frame(maxWidth: Self.readableWidth, alignment: .leading)
            .padding(24)
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
        toggleRow("Launch at login",
                  isOn: $preferences.launchAtLoginEnabled,
                  caption: "Start in the menu bar when you log in.",
                  help: "Revoke it any time in System Settings → General → Login Items.")
        Divider()
        toggleRow("Hide the Dock icon",
                  isOn: $preferences.hideFromDockEnabled,
                  caption: "Run in the menu bar only, with no Dock icon.",
                  help: "Applies immediately and stays that way — it doesn't depend on whether a window is open. SherlockEQ's menus still appear when a window is in front.")
    }

    // MARK: - Appearance

    @ViewBuilder private var appearanceContent: some View {
        colorRow(label: "Left ear", binding: $preferences.leftEarColor, defaultColor: AppPreferences.defaultLeftEarColor)
        colorRow(label: "Right ear", binding: $preferences.rightEarColor, defaultColor: AppPreferences.defaultRightEarColor)
        caption("Used for curves, audiogram thresholds, and EQ sliders.")
        Divider()
        toggleRow("Show EQ and quick tone controls in popover",
                  isOn: $preferences.showPopoverEQCurve,
                  caption: "A live curve plus Bass, Mids, and Treble nudges.",
                  help: "Turn it off for a shorter popover. Detailed editing always happens on the Equalizer screen.")
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
        toggleRow("Global Reference Mode shortcut",
                  isOn: $preferences.globalReferenceShortcutEnabled,
                  caption: "⌘⇧B works even when SherlockEQ is in the background.",
                  help: "Reference Mode bypasses all processing so you hear the source unchanged. ⌘B always works when the window is key; the global shortcut is off by default because it can collide with other apps.")
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
        caption("Point at iCloud Drive or an external disk to back up or sync.")

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
        caption("AutoEQ .txt files every profile's headphone picker can list by name.")
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
        toggleRow("Show Debug in sidebar",
                  isOn: $preferences.showDebugInSidebar,
                  caption: "Diagnostic counters and test controls.")
        Divider()
        toggleRow("Show metadata on profiles",
                  isOn: $preferences.showProfileMetadata,
                  caption: "Created/modified dates and the unique ID.")
    }

    // MARK: - About

    /// A footer strip rather than a settings category — it holds nothing you
    /// can change, so it doesn't earn a place in the grid beside things you can.
    private var aboutCard: some View {
        cardChrome {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Label("SherlockEQ \(HelpCenter.shared.appVersionString)", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text("Acknowledgments")
                    .font(.callout)
                Button("View…") { acknowledgmentsShown = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .help("Science, software, and prior art behind SherlockEQ.")
    }

    // MARK: - Building blocks

    /// Roughly a comfortable measure for prose plus two control columns.
    private static let readableWidth: CGFloat = 880
    /// Below two of these plus a gutter, the grid drops to one column.
    private static let cardMinWidth: CGFloat = 340
    private static let cardSpacing: CGFloat = 16

    /// A row whose control sits at the **trailing** edge, with an optional
    /// one-line description beneath.
    ///
    /// The old rows put the control immediately after its label, so no two
    /// lined up and the eye had to hunt for each switch. Pinning controls
    /// right gives the card a single scan column.
    ///
    /// `help` carries the nuance the caption used to: a caption is one line
    /// of orientation, and the detail belongs in a tooltip or Help rather
    /// than as a paragraph the user re-reads every visit.
    @ViewBuilder
    private func settingRow<Control: View>(
        _ title: LocalizedStringKey,
        caption: LocalizedStringKey? = nil,
        help: LocalizedStringKey? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                control()
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(help ?? caption ?? title)
    }

    /// Convenience for the common case: a switch at the trailing edge.
    @ViewBuilder
    private func toggleRow(
        _ title: LocalizedStringKey,
        isOn: Binding<Bool>,
        caption: LocalizedStringKey? = nil,
        help: LocalizedStringKey? = nil
    ) -> some View {
        settingRow(title, caption: caption, help: help) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(title)
        }
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The card chrome. Title lives *inside* the card rather than on a
    /// separate header bar — the border already separates categories, so a
    /// heavy header would be a second divider doing the same job.
    @ViewBuilder
    private func cardChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.14)))
    }

    private func cardTitle(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }

    /// An always-open category. Everyday preferences shouldn't need a click
    /// to reveal.
    @ViewBuilder
    private func card<Content: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder _ content: @escaping () -> Content
    ) -> some View {
        cardChrome {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle(title, systemImage: systemImage)
                content()
            }
        }
    }

    /// A folded category, for the specialised ones. Kept collapsible because
    /// these are genuinely infrequent and long — not because settings in
    /// general deserve hiding.
    @ViewBuilder
    private func disclosureCard<Content: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder _ content: @escaping () -> Content
    ) -> some View {
        cardChrome {
            DisclosureGroup(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                cardTitle(title, systemImage: systemImage)
            }
        }
    }
}
