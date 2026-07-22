import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Audiogram section of the main window. Edits the *active* profile's
/// per-ear audiograms. Derived `EQBand`s are persisted alongside every change
/// so Session 9's audio wiring can pick them up directly.
struct AudiogramView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var audioState: AudioState

    private enum EarTab: String, CaseIterable, Hashable {
        case left = "Left ear"
        case right = "Right ear"
    }
    @State private var tab: EarTab = .left
    @State private var showingApplySheet = false
    @State private var showingListeningCheck = false
    @State private var confirmingClearAudiogram = false
    /// Numeric threshold table starts collapsed on a fresh profile (the chart
    /// and Listening Check lead); expands once an audiogram has been entered.
    @State private var numericExpanded = false

    var body: some View {
        if let profile = audioState.activeProfile(in: profileStore) {
            content(profile)
        } else {
            ContentUnavailableView(
                "No active profile",
                systemImage: "ear",
                description: Text("Make a profile active from the Profiles section to edit its audiogram.")
            )
        }
    }

    @ViewBuilder private func content(_ profile: HearingProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(profile)
                earPicker
                chartCard(profile)
                // Correction style — Steady vs Adaptive (phase4 §6.1).
                // Only meaningful once an audiogram exists.
                if hasAudiogram(profile) {
                    correctionStyleCard(profile)
                }
                // Acclimatization ramp status (spec §5) — the correction
                // below is intentionally running at partial strength.
                AcclimatizationChip()
                // Notch-vs-correction conflict (spec §6): the derived
                // correction below may be boosting exactly where the
                // user's tinnitus notch cuts.
                CorrectionConflictChip(crossLink: .tinnitusNotch)
                editorCard(profile)
                previewCard(profile)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Audiogram — \(profile.name)")
        .sheet(isPresented: $showingApplySheet) {
            ApplyAudiogramSheet(source: profile)
                .environmentObject(profileStore)
        }
        .sheet(isPresented: $showingListeningCheck) {
            ListeningCheckView()
                .environmentObject(audioState)
                .environmentObject(profileStore)
        }
        // Destructive and previously un-confirmed: clearing also resets the
        // adjustment-strength dial (see HearingProfile.clearAudiogram), so
        // the dialog says exactly what goes and what stays.
        .confirmationDialog(
            "Clear this audiogram?",
            isPresented: $confirmingClearAudiogram,
            titleVisibility: .visible
        ) {
            Button("Clear Audiogram", role: .destructive) {
                if let live = audioState.activeProfile(in: profileStore) {
                    clearAudiogram(live)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the thresholds and the hearing adjustment derived from them, and resets adjustment strength to 100%. Manual EQ, the tinnitus notch, and headphone correction are kept. Undo restores everything.")
        }
    }

    // MARK: - Sections

    private func header(_ profile: HearingProfile) -> some View {
        HStack(spacing: 14) {
            Image(systemName: profile.symbol)
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("Editing \(profile.name)").font(.title3.weight(.semibold))
                Text("Enter the dB HL values from your audiologist report, drag points on the chart — or run the Listening Check to estimate them here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Provenance (spec §4.5): where this audiogram came from is
                // never ambiguous — a Listening Check estimate is framed
                // differently from a typed-in clinical report.
                if let date = profile.audiogramDate {
                    Text("Audiogram from \(profile.audiogramSource.label), \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("No hearing thresholds have been entered.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            listeningCheckButton(profile)
            Menu {
                Button("Import Audiogram…", systemImage: "square.and.arrow.down") { importAudiogram(into: profile) }
                Button("Export Audiogram…", systemImage: "square.and.arrow.up") { exportAudiogram(profile) }
                Divider()
                Button("Apply to Other Profiles…", systemImage: "person.2") { showingApplySheet = true }
                // Gate on "is there anything to clear", not provenance: a
                // pre-0.9.0 audiogram can carry real thresholds + an audible
                // correction, and that's exactly the state a user needs to be
                // able to clear from here.
                if profile.hasAudiogramData {
                    Divider()
                    Button("Clear Audiogram…", systemImage: "trash", role: .destructive) { confirmingClearAudiogram = true }
                }
            } label: {
                Label("Manage Audiogram", systemImage: "ear")
            }
            .fixedSize()
            .help("Import, export, clear, or copy this audiogram to your other profiles")
            HelpContextButton(.audiogramProfiles, label: "audiogram and hearing profiles")
        }
    }

    // MARK: - Import / Export

    /// Write the active profile's audiogram out as a portable
    /// `AudiogramInterchange` JSON (HealthKit-shaped: Hz + per-ear dB HL).
    private func exportAudiogram(_ profile: HearingProfile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(profile.name) Audiogram.json"
        panel.canCreateDirectories = true
        panel.title = "Export Audiogram"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let doc = AudiogramInterchange.from(
            left: profile.leftEar.thresholds,
            right: profile.rightEar.thresholds,
            source: profile.name
        )
        // Errors surface via ProfileStore.lastError → NoticeCenter banner.
        try? profileStore.exportAudiogram(doc, to: url)
    }

    /// Read an audiogram JSON and apply it onto the active profile — recomputing
    /// its correction layer while leaving its EQ, notch, and compensation alone.
    /// Saving the active profile re-applies it to the engine automatically.
    private func importAudiogram(into profile: HearingProfile) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import Audiogram"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let doc = try? profileStore.importAudiogram(from: url) else { return }
        try? profileStore.save(
            profile.applyingAudiogram(doc, modifiedAt: Date()),
            actionName: "Import audiogram into \(profile.name)"
        )
    }

    /// Reset the audiogram back to the not-entered state (flat thresholds, no
    /// derived correction, no provenance/ramp). Leaves EQ, notch, and device
    /// links alone — only the hearing-adjustment layer is cleared.
    private func clearAudiogram(_ profile: HearingProfile) {
        // Live copy (CX-05), then the model's own reset — the mutation lives
        // on HearingProfile so its semantics (incl. the strength reset) are
        // unit-tested rather than view-only.
        var updated = profileStore.profiles.first { $0.id == profile.id } ?? profile
        updated.clearAudiogram()
        try? profileStore.save(updated, actionName: "Clear audiogram for \(profile.name)")
        numericExpanded = false
    }

    private var earPicker: some View {
        Picker("", selection: $tab) {
            ForEach(EarTab.allCases, id: \.self) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
    }

    @ViewBuilder private func chartCard(_ profile: HearingProfile) -> some View {
        card {
            Text(tab.rawValue + " — threshold chart")
                .font(.subheadline.weight(.semibold))
            AudiogramChartView(
                thresholds: audiogramBinding(for: profile),
                earColor: earColor,
                entered: profile.hasEnteredAudiogram
            )
            Text("Lower on the chart means a higher threshold — you need more level to hear that pitch. 0 dB HL (normal) sits at the top, per the audiology convention.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func editorCard(_ profile: HearingProfile) -> some View {
        card {
            DisclosureGroup(isExpanded: $numericExpanded) {
                ThresholdEditor(
                    thresholds: audiogramBinding(for: profile),
                    earColor: earColor,
                    entered: profile.hasEnteredAudiogram
                )
                .padding(.top, 8)
            } label: {
                Text("Numeric entry")
                    .font(.subheadline.weight(.semibold))
            }
            .onAppear { numericExpanded = profile.hasEnteredAudiogram }
        }
    }

    /// Listening Check entry point — prominent on an empty profile (the
    /// easiest path to a first audiogram), secondary once one exists.
    @ViewBuilder private func listeningCheckButton(_ profile: HearingProfile) -> some View {
        let label = Label("Listening Check…", systemImage: "ear.badge.waveform")
        let help = "Estimate your thresholds with a guided tone check — no clinical audiogram needed."
        if profile.hasEnteredAudiogram {
            Button { showingListeningCheck = true } label: { label }
                .buttonStyle(.bordered)
                .help(help)
        } else {
            Button { showingListeningCheck = true } label: { label }
                .buttonStyle(.borderedProminent)
                .help(help)
        }
    }

    /// Whether the profile has any audiogram-derived correction to style.
    private func hasAudiogram(_ profile: HearingProfile) -> Bool {
        !profile.leftEar.correctionBands.isEmpty || !profile.rightEar.correctionBands.isEmpty
    }

    /// Steady vs Adaptive selector (phase4 §6.1). Writes
    /// `profile.correctionMode`; saving the active profile re-applies it to
    /// the engine, which swaps the correction between the static cascade
    /// and the adaptive stage.
    @ViewBuilder private func correctionStyleCard(_ profile: HearingProfile) -> some View {
        card {
            HStack(spacing: 12) {
                Text("Adjustment style")
                    .font(.subheadline.weight(.semibold))
                Picker("Adjustment style", selection: correctionModeBinding(for: profile)) {
                    Text("Steady").tag(CorrectionMode.steady)
                    Text("Adaptive").tag(CorrectionMode.adaptive)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
                Spacer()
            }
            Text("Steady applies the same adjustment at every volume. Adaptive gives quieter passages more adjustment and louder passages less, using your playback calibration to judge levels. Start with Steady; try Adaptive once your calibration is set.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Honesty line (§6.3): Adaptive's accuracy depends on the
            // playback calibration; reduced-depth mode (§7.3) when unset.
            if profile.correctionMode == .adaptive && !audioState.hasUserCalibration {
                Label {
                    Text("Playback calibration hasn't been set — Adaptive is running in its reduced-depth mode. Calibrate in Safe Listening for the full effect.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                }
                .foregroundStyle(.orange)
            }
        }
    }

    private func correctionModeBinding(for profile: HearingProfile) -> Binding<CorrectionMode> {
        Binding(
            get: { profile.correctionMode },
            set: { newMode in
                guard newMode != profile.correctionMode else { return }
                var updated = profile
                updated.correctionMode = newMode
                try? profileStore.save(
                    updated,
                    actionName: "Set adjustment style to \(newMode == .adaptive ? "Adaptive" : "Steady")"
                )
            }
        )
    }

    @ViewBuilder private func previewCard(_ profile: HearingProfile) -> some View {
        card {
            if profile.correctionMode == .adaptive && hasAudiogram(profile) {
                // Adaptive preview (phase4 §6.2): the level-dependent
                // correction family for the displayed ear — the single
                // combined curve below can't represent a correction that
                // changes with input level.
                AdaptivePreviewView(
                    thresholds: tab == .left ? profile.leftEar.thresholds : profile.rightEar.thresholds,
                    correctionBands: tab == .left ? profile.leftEar.correctionBands : profile.rightEar.correctionBands,
                    userBands: tab == .left ? profile.leftEar.bands : profile.rightEar.bands,
                    strength: profile.effectiveCorrectionStrength(),
                    targetStrength: profile.compensationFactor,
                    earLabel: tab == .left ? "left ear" : "right ear",
                    earColor: earColor
                )
            } else {
                // The full result the listener hears: EFFECTIVE hearing
                // correction (target strength × acclimatization ramp — same
                // helper the engine consumes, phase3 §5) summed with the
                // user/preset EQ, per ear.
                EQPreviewView(
                    leftBands: profile.effectiveCorrectionBands().left + profile.leftEar.bands,
                    rightBands: profile.effectiveCorrectionBands().right + profile.rightEar.bands,
                    targetStrength: profile.compensationFactor,
                    effectiveStrength: profile.effectiveCorrectionStrength()
                )
            }
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private var earColor: Color { tab == .left ? audioState.preferences.leftEarColor : audioState.preferences.rightEarColor }

    /// Binding that reads/writes the active-tab ear's audiogram thresholds and
    /// rebuilds the matching EQ bands on every mutation so the derived curve
    /// (and Session 9's engine application) stays in sync.
    private func audiogramBinding(for profile: HearingProfile) -> Binding<[AudiogramPoint]> {
        Binding(
            get: { tab == .left ? profile.leftEar.thresholds : profile.rightEar.thresholds },
            set: { newPoints in
                // Mutate the store's LIVE copy — `profile` is a body-render
                // snapshot, and saving it whole would clobber any edit made
                // from another surface since this view last rendered.
                var updated = profileStore.profiles.first { $0.id == profile.id } ?? profile
                // Derived at FULL strength — the user's target strength ×
                // the acclimatization ramp is applied at consumption time
                // via effectiveCorrectionBands (phase3 §5).
                let hadCorrectionBefore = !updated.leftEar.correctionBands.isEmpty
                    || !updated.rightEar.correctionBands.isEmpty
                let derived = AudiogramConversion.bands(
                    for: newPoints,
                    compensationFactor: 1.0
                )
                // The hearing correction lands in its OWN `correctionBands`
                // layer — never in `bands` — so EQ presets/edits layer on top
                // of it instead of overwriting it. We also strip any correction
                // a legacy profile had baked into `bands` (pre-layer) so
                // re-editing the audiogram doesn't double-apply it. User-authored
                // shelves, notches, and off-slot parametric bands are preserved.
                if tab == .left {
                    updated.leftEar.thresholds = newPoints
                    updated.leftEar.correctionBands = derived
                    updated.leftEar.bands = EQBandLookup.removingAudiogramBands(matching: derived, from: updated.leftEar.bands)
                } else {
                    updated.rightEar.thresholds = newPoints
                    updated.rightEar.correctionBands = derived
                    updated.rightEar.bands = EQBandLookup.removingAudiogramBands(matching: derived, from: updated.rightEar.bands)
                }
                updated.startAcclimatizationIfFirstAudiogram(hadCorrectionBefore: hadCorrectionBefore)
                updated.audiogramSource = .manual
                updated.audiogramDate = Date()
                try? profileStore.save(updated)
            }
        )
    }
}
