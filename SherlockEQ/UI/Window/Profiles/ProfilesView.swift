import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Profiles section of the main window. Master/detail layout via plain `HStack`
/// — nesting `HSplitView` inside `NavigationSplitView` confuses the outer
/// layout and squishes everything. We get a fixed-width list column on the
/// left and a scrolling detail on the right.
///
/// Selection here is *editing* selection, distinct from
/// `AudioState.activeProfileID` (the profile being applied to the audio
/// engine). The detail's "Make Active" button bridges the two.
struct ProfilesView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var audioState: AudioState

    @State private var selection: UUID?
    @State private var profileToDelete: HearingProfile?
    @State private var showRestoreConfirm = false

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: 260)
                .background(.regularMaterial)
            Divider()
            detailColumn
        }
        .navigationTitle("Profiles")
        .onAppear { syncSelectionWithActive() }
        .onChange(of: profileStore.profiles) { _, _ in
            if let id = selection, !profileStore.profiles.contains(where: { $0.id == id }) {
                selection = profileStore.profiles.first?.id
            } else if selection == nil {
                syncSelectionWithActive()
            }
        }
        .confirmationDialog(
            "Delete \(profileToDelete?.name ?? "profile")?",
            isPresented: deletionDialogBinding,
            titleVisibility: .visible,
            presenting: profileToDelete
        ) { profile in
            Button("Delete", role: .destructive) { confirmDelete(profile) }
            Button("Cancel", role: .cancel) { profileToDelete = nil }
        } message: { _ in
            Text("This removes the profile's JSON file. This cannot be undone.")
        }
        .confirmationDialog(
            "Restore built-in presets?",
            isPresented: $showRestoreConfirm,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) { profileStore.restoreFactoryPresets() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Recreates Voice Clarity, Music Balanced, Gentle Listening, and Reduce Boom and resets any edits to them. Your own profiles are untouched.")
        }
    }

    // MARK: - List column

    @ViewBuilder private var listColumn: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(profileStore.profiles) { profile in
                    ProfileListItem(
                        profile: profile,
                        isActive: audioState.activeProfileID == profile.id
                    )
                    .tag(profile.id)
                    .contextMenu {
                        Button("Make Active") { audioState.activeProfileID = profile.id }
                            .disabled(audioState.activeProfileID == profile.id)
                        Button("Duplicate") { duplicate(profile) }
                        if profile.isBuiltIn {
                            Button("Reset to Default") {
                                profileStore.resetProfileToFactory(profile.id)
                            }
                            .disabled(!profileStore.differsFromFactory(profile))
                        }
                        Button("Export…") { exportProfile(profile) }
                        Divider()
                        Button("Delete", role: .destructive) { profileToDelete = profile }
                            .disabled(profileStore.profiles.count <= 1)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)

            Divider()
            listToolbar
        }
    }

    @ViewBuilder private var listToolbar: some View {
        HStack(spacing: 8) {
            // Primary action is labeled; the rest live in a clearly-labeled
            // overflow menu (the old row of bare icons was hard to read).
            Button(action: createNew) {
                Label("New Profile", systemImage: "plus")
            }
            .controlSize(.small)

            Spacer()

            Menu {
                Button {
                    duplicateSelected()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .disabled(selectedProfile == nil)

                Button(role: .destructive) {
                    deleteSelected()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selectedProfile == nil || profileStore.profiles.count <= 1)

                Divider()

                Button {
                    importProfiles()
                } label: {
                    Label("Import from JSON…", systemImage: "square.and.arrow.down")
                }
                Button {
                    exportSelected()
                } label: {
                    Label("Export to JSON…", systemImage: "square.and.arrow.up")
                }
                .disabled(selectedProfile == nil)

                Divider()

                Button {
                    showRestoreConfirm = true
                } label: {
                    Label("Restore built-in presets…", systemImage: "arrow.clockwise")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Duplicate, delete, import, export, or restore presets")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Detail column

    @ViewBuilder private var detailColumn: some View {
        if let id = selection, let profile = profileStore.profiles.first(where: { $0.id == id }) {
            ProfileDetailView(profileID: profile.id) { copy in
                // Built-in banner's Duplicate button → also follow the new
                // copy in the master list, so the user is editing it.
                selection = copy.id
            }
        } else {
            ContentUnavailableView(
                "No profile selected",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text("Pick one from the list, or create a new profile.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    private var selectedProfile: HearingProfile? {
        guard let id = selection else { return nil }
        return profileStore.profiles.first { $0.id == id }
    }

    private var deletionDialogBinding: Binding<Bool> {
        Binding(
            get: { profileToDelete != nil },
            set: { if !$0 { profileToDelete = nil } }
        )
    }

    private func syncSelectionWithActive() {
        if selection == nil {
            selection = audioState.activeProfileID ?? profileStore.profiles.first?.id
        }
    }

    private func createNew() {
        let newProfile = HearingProfile.makeDefault(name: uniqueName(base: "New Profile"))
        do {
            try profileStore.save(newProfile)
            selection = newProfile.id
        } catch { /* surfaced via ProfileStore.lastError (DebugView) */ }
    }

    private func duplicateSelected() {
        guard let p = selectedProfile else { return }
        duplicate(p)
    }

    private func duplicate(_ source: HearingProfile) {
        var copy = source.duplicated()
        copy.name = uniqueName(base: "\(source.name) Copy")
        do {
            try profileStore.save(copy)
            selection = copy.id
        } catch { /* see note above */ }
    }

    private func deleteSelected() {
        guard let p = selectedProfile, profileStore.profiles.count > 1 else { return }
        profileToDelete = p
    }

    private func confirmDelete(_ profile: HearingProfile) {
        defer { profileToDelete = nil }
        do {
            try profileStore.delete(profile)
            if audioState.activeProfileID == profile.id {
                audioState.activeProfileID = profileStore.profiles.first?.id
            }
        } catch { /* see note above */ }
    }

    private func uniqueName(base: String) -> String {
        let existing = Set(profileStore.profiles.map(\.name))
        if !existing.contains(base) { return base }
        var i = 2
        while existing.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    // MARK: - Import / Export

    private func exportSelected() {
        guard let p = selectedProfile else { return }
        exportProfile(p)
    }

    private func exportProfile(_ profile: HearingProfile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(profile.name).json"
        panel.canCreateDirectories = true
        panel.title = "Export \(profile.name)"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try profileStore.exportProfile(profile, to: url)
        } catch { /* surfaced via ProfileStore.lastError (DebugView) */ }
    }

    private func importProfiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = "Import profiles"
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        var lastImported: HearingProfile?
        for url in panel.urls {
            if let imported = try? profileStore.importProfile(from: url) {
                lastImported = imported
            }
        }
        if let imported = lastImported {
            selection = imported.id
        }
    }
}
