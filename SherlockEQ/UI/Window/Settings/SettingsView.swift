import SwiftUI

/// App-wide settings. Sections: Startup, Output (master gain), Peak
/// limiter, Appearance (per-ear colors), AutoEQ library folder, Profile
/// backup location, Reference Mode global shortcut, About.
struct SettingsView: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore
    @State private var acknowledgmentsShown = false
    @State private var relocationAlert: RelocationPrompt?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                startupSection
                outputSection
                limiterSection
                appearanceSection
                shortcutsSection
                autoEQLibrarySection
                profilesFolderSection
                diagnosticsSection
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
    }

    private struct RelocationPrompt: Identifiable {
        let url: URL
        var id: URL { url }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "gearshape")
                .font(.system(size: 32))
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings").font(.title2.weight(.semibold))
                Text("App-wide preferences").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var startupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Startup").font(.headline)
            sectionBox {
                HStack {
                    Toggle("Launch at login", isOn: $audioState.launchAtLoginEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Spacer()
                }
                Text("When enabled, SherlockEQ starts automatically when you log in and runs in the menu bar. You can revoke this in System Settings → General → Login Items.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                Divider()
                HStack {
                    Toggle("Hide from Dock when window is closed", isOn: $audioState.hideFromDockEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Spacer()
                }
                Text("When enabled, the Dock icon disappears after you close the main window — SherlockEQ keeps running in the menu bar. Turn this off if the macOS menu bar fails to redraw when you reopen the window; you'll get a permanent Dock icon in exchange.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Output").font(.headline)
            sectionBox {
                masterGainRow
                Divider()
                Text("Applied after the peak limiter — the limiter still catches summed peaks, so boost up to +12 dB is safe. Persists across launches.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    private var masterGainRow: some View {
        let isZero = abs(audioState.masterGainDB) < 0.05
        return HStack {
            Text("Master gain")
                .foregroundStyle(.secondary)
                .frame(minWidth: 120, alignment: .leading).layoutPriority(1)
            Slider(
                value: Binding(
                    get: { audioState.masterGainDB },
                    set: { audioState.masterGainDB = $0 }
                ),
                in: -60...12
            )
            .controlSize(.small)
            Text(gainLabel(audioState.masterGainDB))
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
                .frame(width: 72, alignment: .trailing)
            Button {
                audioState.masterGainDB = 0
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

    private var limiterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Peak limiter").font(.headline)
            sectionBox {
                limiterParamRow(
                    label: "Attack",
                    value: audioState.limiterAttackMs,
                    range: 1.0...30.0,
                    defaultValue: 12.0,
                    format: { String(format: "%.1f ms", $0) },
                    set: { audioState.limiterAttackMs = $0 }
                )
                Divider()
                limiterParamRow(
                    label: "Decay",
                    value: audioState.limiterDecayMs,
                    range: 1.0...60.0,
                    defaultValue: 24.0,
                    format: { String(format: "%.1f ms", $0) },
                    set: { audioState.limiterDecayMs = $0 }
                )
                Divider()
                limiterParamRow(
                    label: "Pre-gain",
                    value: audioState.limiterPreGainDB,
                    range: -40...40,
                    defaultValue: 0,
                    format: { String(format: "%+.1f dB", $0) },
                    set: { audioState.limiterPreGainDB = $0 }
                )
                Divider()
                Text("Shorter attack catches sharp transients but adds distortion. Longer decay smooths out sustained signals at the cost of pumping. Pre-gain pushes the signal harder into the limiter before it triggers.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
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

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Appearance").font(.headline)
            sectionBox {
                colorRow(
                    label: "Left ear",
                    binding: $audioState.leftEarColor,
                    defaultColor: AudioState.defaultLeftEarColor
                )
                Divider()
                colorRow(
                    label: "Right ear",
                    binding: $audioState.rightEarColor,
                    defaultColor: AudioState.defaultRightEarColor
                )
                Divider()
                Text("Colors used for the left/right curves, audiogram thresholds, and EQ band sliders. Helpful for users who can't distinguish the default blue/red.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
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
            Text(binding.wrappedValue.hexString)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
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

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About").font(.headline)
            sectionBox {
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
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Welcome tour").font(.callout.weight(.medium))
                        Text("Replay the first-launch introduction and permission walkthrough.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Replay intro") { AppDelegate.shared?.showOnboardingWindow() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
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

    // MARK: - Reference Mode shortcut

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reference Mode").font(.headline)
            sectionBox {
                HStack {
                    Toggle("Global ⌘⇧B toggles Reference Mode", isOn: $audioState.globalReferenceShortcutEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Spacer()
                }
                Text("When enabled, ⌘⇧B toggles bypass even when SherlockEQ is in the background. The local ⌘B menu item in Audio → Toggle Reference Mode keeps working when the main window is key. Off by default because system-wide shortcuts can collide with whatever app is in front.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diagnostics").font(.headline)
            sectionBox {
                HStack {
                    Toggle("Show Debug in sidebar", isOn: $audioState.showDebugInSidebar)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Spacer()
                }
                Text("Adds a Debug entry to the sidebar's App group with diagnostic counters, force-dose controls, and a notification test. Off by default — turn it on only when troubleshooting.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    // MARK: - AutoEQ library folder

    private var autoEQLibrarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Headphone correction library").font(.headline)
            sectionBox {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        if let folder = audioState.autoEQLibraryFolder {
                            Text(folder.path)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            let count = AutoEQLibrary.entries(in: folder).count
                            Text("\(count) .txt file\(count == 1 ? "" : "s") found")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No library folder set")
                                .font(.callout)
                            Text("Profile Detail's headphone-correction picker falls back to a file picker each time.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Choose…") { chooseAutoEQLibrary() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    if audioState.autoEQLibraryFolder != nil {
                        Button(role: .destructive) { audioState.autoEQLibraryFolder = nil } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Clear library folder")
                    }
                }
                Text("Point this at a folder of AutoEQ .txt files (one per headphone). Profile Detail's headphone-correction button becomes a menu listing each file by name.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    private func chooseAutoEQLibrary() {
        let panel = NSOpenPanel()
        panel.title = "Choose AutoEQ library folder"
        panel.prompt = "Use folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let current = audioState.autoEQLibraryFolder {
            panel.directoryURL = current
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        audioState.autoEQLibraryFolder = url
    }

    // MARK: - Profiles folder

    private var profilesFolderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Profiles folder").font(.headline)
            sectionBox {
                HStack(spacing: 10) {
                    Image(systemName: "tray.full")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profileStore.directory.path)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if profileStore.directory.standardizedFileURL == ProfileStore.defaultDirectory().standardizedFileURL {
                            Text("Default (Application Support)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Custom location")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                        .help("Switch back to the default Application Support location")
                    }
                }
                Text("Point this at iCloud Drive / Dropbox / an external disk to back up or sync your profiles. Sandbox is off, so SherlockEQ can read anywhere you have access — no security-scoped bookmark needed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
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
            // Best-effort surfacing via the standard error UI is overkill;
            // a one-line alert keeps the failure visible without ceremony.
            let alert = NSAlert()
            alert.messageText = "Couldn't switch profiles folder"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
