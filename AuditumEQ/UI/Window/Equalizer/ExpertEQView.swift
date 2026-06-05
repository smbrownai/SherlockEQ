import SwiftUI

/// Parametric EQ surface: full-control biquad editing per ear.
/// Drag nodes on the canvas, tune the selected band's Q / filter type /
/// gain / freq below, or add/remove bands from the toolbar.
struct ExpertEQView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var audioState: AudioState

    private enum EarTab: String, CaseIterable, Hashable {
        case left = "Left ear"
        case right = "Right ear"
    }
    @State private var tab: EarTab = .left
    @State private var selectedBandID: UUID?
    /// Display preference for the Q/BW readout — Q value vs equivalent
    /// bandwidth in octaves. Storage is always Q internally.
    @State private var showQAsOctaves: Bool = false
    /// Reads the active profile's `separateChannels` flag. Toggle
    /// lives on Profile Detail. Default for new profiles is false
    /// (linked) — band edits propagate to both ears.
    private var linkChannels: Bool {
        !(audioState.activeProfile(in: profileStore)?.separateChannels ?? false)
    }
    /// Selected underlay visualisation, persisted across launches.
    @AppStorage("auditumeq.expertVizMode") private var vizModeRaw: String = CanvasVizMode.spectrum.rawValue

    // Canvas layer visibility — persisted per-user via @AppStorage so the
    // layout the user picked last session is what they see next launch.
    // Each chip in the layer strip mutates one of these.
    @AppStorage("auditumeq.layer.output")    private var showOutputLayer    = true
    @AppStorage("auditumeq.layer.input")     private var showInputLayer     = false
    @AppStorage("auditumeq.layer.eq")        private var showEQLayer        = true
    @AppStorage("auditumeq.layer.audiogram") private var showAudiogramLayer = true
    @AppStorage("auditumeq.layer.safety")    private var showSafetyLayer    = false
    @AppStorage("auditumeq.layer.peaks")     private var showPeaksLayer     = false
    // Spectrogram-mode layers (separate keys so toggling them doesn't
    // disturb the user's Spectrum-mode chip configuration).
    @AppStorage("auditumeq.spectrogram.notch")       private var showNotchLineLayer    = true
    @AppStorage("auditumeq.spectrogram.regions")     private var showRegionLabelsLayer = true
    @AppStorage("auditumeq.spectrogram.legend")      private var showColorLegendLayer  = true
    @AppStorage("auditumeq.spectrogram.time")        private var showTimeAxisLayer     = true
    @AppStorage("auditumeq.spectrogram.persistence") private var showPersistenceLayer  = false

    /// Standard 8 bands at audiogram frequencies — used by Quick start
    /// to populate an empty profile with a useful working surface.
    private static let quickStartFrequencies: [Double] = [
        250, 500, 1000, 2000, 3000, 4000, 6000, 8000
    ]

    var body: some View {
        if let profile = audioState.activeProfile(in: profileStore) {
            content(profile)
        } else {
            ContentUnavailableView(
                "No active profile",
                systemImage: "slider.horizontal.3",
                description: Text("Make a profile active to edit its EQ.")
            )
        }
    }

    @FocusState private var canvasFocused: Bool

    @ViewBuilder private func content(_ profile: HearingProfile) -> some View {
        let target = targetBands(for: profile)
        // Wrapped in ScrollView (matching AdvancedEQView) so the view
        // breathes when window height is tight. Outer padding bumped from
        // 20 → 24 to match the rest of the app's window-content margins,
        // and VStack spacing raised so the canvas, controls bar, and notch
        // section don't visually crowd each other.
        ScrollView {
            VStack(spacing: 18) {
                header
            // Layer chips only matter when the spectrum visualisation is
            // active — they toggle pieces of that scene. In Spectrogram /
            // Bars modes the chips would just sit greyed out, so hide the
            // strip entirely instead.
            if vizMode == .spectrum {
                CanvasLayerChipStrip(
                    showInputSpectrum: $showInputLayer,
                    showOutputSpectrum: $showOutputLayer,
                    showEQCurve: $showEQLayer,
                    showAudiogramTarget: $showAudiogramLayer,
                    showSafetyOverlay: $showSafetyLayer,
                    showPeakCallouts: $showPeaksLayer,
                    hasAudiogram: !target.isEmpty,
                    earColor: earColor
                )
            } else if vizMode == .spectrogram {
                SpectrogramLayerChipStrip(
                    showEQCurve: $showEQLayer,
                    showNotchLine: $showNotchLineLayer,
                    showRegionLabels: $showRegionLabelsLayer,
                    showColorLegend: $showColorLegendLayer,
                    showTimeAxis: $showTimeAxisLayer,
                    showPersistence: $showPersistenceLayer,
                    earColor: earColor,
                    hasNotch: profile.leftNotch.enabled || profile.rightNotch.enabled
                )
            }
            LiveParametricCanvas(
                spectrum: audioState.spectrum,
                preSpectrum: audioState.preSpectrum,
                includeHistory: true,
                bands: bandsBinding(for: profile),
                shadowBands: shadowBands(for: profile),
                targetBands: target,
                notch: profile.leftNotch,
                spectrumSampleRate: audioState.audio.outputSampleRate ?? 48_000,
                earColor: earColor,
                shadowColor: shadowColor,
                vizMode: vizMode,
                selectedBandID: $selectedBandID,
                showInputSpectrum: showInputLayer,
                showOutputSpectrum: showOutputLayer,
                showEQCurve: showEQLayer,
                showAudiogramTarget: showAudiogramLayer,
                showSafetyOverlay: showSafetyLayer,
                showPeakCallouts: showPeaksLayer,
                showNotchLine: showNotchLineLayer,
                showRegionLabels: showRegionLabelsLayer,
                showColorLegend: showColorLegendLayer,
                showTimeAxis: showTimeAxisLayer,
                showPersistence: showPersistenceLayer,
                // Profile's user-set ceiling + AudioState's SPL calibration
                // drive the safety threshold curve. With both at their
                // defaults the curve sits where the old heuristic was;
                // editing the ceiling in Safe Listening or the calibration
                // in its settings card immediately reshapes the danger fill.
                safetyCeilingDBA: profile.safeListeningCeilingDB,
                calibrationOffsetDBA: audioState.calibrationOffsetDBA
            )
            // Roomier canvas — there's plenty of vertical real estate
            // below the canvas on Expert, and the spectrum + EQ curve
            // both benefit from more pixels per dB. ~60 % taller than
            // the original 280pt while still leaving the band table
            // and controls bar comfortably above the fold.
            .frame(minHeight: 450)
            .focusable()
            .focused($canvasFocused)
            // Band navigation: Tab and L go forward, J goes back.
            // Shift+Tab is reserved by macOS for focus traversal and can't
            // be intercepted — hence the gamer-style J/L pair as the
            // bidirectional binding.
            .onKeyPress(.tab) {
                cycleSelection(forward: true, in: profile)
                return .handled
            }
            .onKeyPress { press in handleKey(press, in: profile) }
            .onTapGesture { canvasFocused = true }
            controlsBar(profile)
            shortcutsKey
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Map keys to selected-band edits (spec §5.9 power-user goal). Each
    /// edit reads the band fresh because the binding's captured profile may
    /// be stale after the previous edit's save.
    private func handleKey(_ press: KeyPress, in profile: HearingProfile) -> KeyPress.Result {
        // Tab is handled by an explicit `.onKeyPress(.tab)` upstream. J/L
        // are handled here because they should also work with nothing
        // selected (picks the first/last band, same as Tab does).
        let chars = press.characters.lowercased()
        if chars == "j" {
            cycleSelection(forward: false, in: profile)
            return .handled
        }
        if chars == "l" {
            cycleSelection(forward: true, in: profile)
            return .handled
        }

        guard let id = selectedBandID,
              let band = activeBands(in: profile).first(where: { $0.id == id }) else {
            return .ignored
        }

        let isCmd = press.modifiers.contains(.command)
        let isShift = press.modifiers.contains(.shift)

        // Gain step ladder (priority: most specific modifier wins).
        // ⌘⇧ = ±0.1 dB (fine), ⌘ = ±5 dB (jump), ⇧ = ±0.5 dB (half),
        // no modifier = ±1 dB (default).
        let gainAmount: Double = {
            if isCmd && isShift { return 0.1 }
            if isCmd            { return 5.0 }
            if isShift          { return 0.5 }
            return 1.0
        }()

        // Frequency step ladder — multiplicative for percentage-style
        // sweeps, but ⌘⇧ snaps to ±1 Hz absolute so users can nudge
        // a band by single-Hertz amounts for surgical work near a
        // specific pitch (e.g. dialling in a tinnitus notch).
        // ⌘ = ±50 %, ⇧ = ±15 %, default = ±5 %.
        let freqFactor: Double = {
            if isCmd   { return 1.5 }
            if isShift { return 1.15 }
            return 1.05
        }()

        switch press.key {
        case .upArrow:
            update(band: band) { $0.gaindB = clampDB($0.gaindB + gainAmount) }
            return .handled
        case .downArrow:
            update(band: band) { $0.gaindB = clampDB($0.gaindB - gainAmount) }
            return .handled
        case .leftArrow:
            update(band: band) {
                if isCmd && isShift {
                    $0.frequencyHz = clampHz($0.frequencyHz - 1)
                } else {
                    $0.frequencyHz = clampHz($0.frequencyHz / freqFactor)
                }
            }
            return .handled
        case .rightArrow:
            update(band: band) {
                if isCmd && isShift {
                    $0.frequencyHz = clampHz($0.frequencyHz + 1)
                } else {
                    $0.frequencyHz = clampHz($0.frequencyHz * freqFactor)
                }
            }
            return .handled
        case .delete, .deleteForward:
            removeBand(band)
            return .handled
        case .space:
            update(band: band) { $0.enabled.toggle() }
            return .handled
        case .return:
            update(band: band) { $0.gaindB = 0 }
            return .handled
        default:
            // "[" and "]" tighten/widen Q
            if press.characters == "[" {
                update(band: band) { $0.bandwidth = max(0.1, $0.bandwidth - 0.1) }
                return .handled
            }
            if press.characters == "]" {
                update(band: band) { $0.bandwidth = min(10, $0.bandwidth + 0.1) }
                return .handled
            }
            return .ignored
        }
    }

    private func activeBands(in profile: HearingProfile) -> [EQBand] {
        tab == .left ? profile.leftEar.bands : profile.rightEar.bands
    }

    /// Advance `selectedBandID` to the next (or previous) band, sorted by
    /// frequency so Tab feels like sweeping left→right across the canvas.
    /// Wraps at both ends; nothing-selected + Tab picks the lowest band,
    /// nothing-selected + Shift+Tab picks the highest.
    private func cycleSelection(forward: Bool, in profile: HearingProfile) {
        let sorted = activeBands(in: profile).sorted { $0.frequencyHz < $1.frequencyHz }
        guard !sorted.isEmpty else { return }

        guard let current = selectedBandID,
              let idx = sorted.firstIndex(where: { $0.id == current }) else {
            selectedBandID = (forward ? sorted.first : sorted.last)?.id
            return
        }

        let next = (idx + (forward ? 1 : sorted.count - 1)) % sorted.count
        selectedBandID = sorted[next].id
    }

    // MARK: - Sections

    private var vizMode: CanvasVizMode {
        get { Self.resolveVizMode(vizModeRaw) }
    }

    private var vizModeBinding: Binding<CanvasVizMode> {
        Binding(
            get: { Self.resolveVizMode(vizModeRaw) },
            set: { vizModeRaw = $0.rawValue }
        )
    }

    /// Decode the persisted raw value, coercing any legacy
    /// `.spectrogram` value back to `.spectrum` so a user whose stored
    /// preference predates the temporary hiding doesn't end up showing
    /// a mode whose picker tile no longer exists.
    private static func resolveVizMode(_ raw: String) -> CanvasVizMode {
        let parsed = CanvasVizMode(rawValue: raw) ?? .spectrum
        return CanvasVizMode.userVisibleCases.contains(parsed) ? parsed : .spectrum
    }

    private var header: some View {
        HStack(spacing: 12) {
            // Ear-tab picker is only meaningful when L and R are being
            // edited independently. In linked mode (the default) every
            // edit propagates to both ears, so showing the picker
            // would suggest a choice that doesn't exist. Drives off
            // the same `auditumeq.separateChannels` AppStorage key as
            // every other EQ tab — single switch in Settings →
            // Equalizer flips the whole app's behaviour at once.
            if !linkChannels {
                Picker("", selection: $tab) {
                    ForEach(EarTab.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }

            Picker("", selection: vizModeBinding) {
                ForEach(CanvasVizMode.userVisibleCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 160)
            .help("Pick the visualisation behind the EQ curve")

            Spacer()

            Label("\(activeBands.count) band\(activeBands.count == 1 ? "" : "s")",
                  systemImage: "rectangle.stack")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("", selection: $showQAsOctaves) {
                Text("Q").tag(false)
                Text("Oct").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 80)
            .help("Display the selected band's width as Q or as octave bandwidth")

            Button {
                addBand()
            } label: {
                Label("Add band", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func controlsBar(_ profile: HearingProfile) -> some View {
        if let id = selectedBandID, let band = activeBands.first(where: { $0.id == id }) {
            HStack(spacing: 14) {
                Toggle("On", isOn: enabledBinding(for: band))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .frame(width: 70, alignment: .leading)

                Menu {
                    ForEach(EQFilterType.allCases, id: \.self) { type in
                        Button(filterTypeLabel(type)) { setType(for: band, to: type) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.below.rectangle")
                        Text(filterTypeLabel(band.filterType))
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 150, alignment: .leading)

                paramRow("Freq", value: Int(band.frequencyHz), unit: "Hz") { dragged in
                    update(band: band) { $0.frequencyHz = clampHz($0.frequencyHz + Double(dragged) * 5) }
                }

                // Pre-format to %+.1f so the readout reflects the
                // 0.1 dB drag resolution. Casting to Int (the previous
                // behaviour) threw away every sub-integer move — the
                // user could see the slope of the curve change but
                // the number wouldn't budge until they crossed to the
                // next whole dB.
                paramRow("Gain",
                         value: String(format: "%+.1f", band.gaindB),
                         unit: "dB") { dragged in
                    update(band: band) { $0.gaindB = clampDB($0.gaindB + Double(dragged) * 0.1) }
                }

                targetDeltaReadout(for: band, profile: profile)

                let widthLabel = showQAsOctaves ? "BW" : "Q"
                let widthDisplay: String = showQAsOctaves
                    ? String(format: "%.2f oct", Self.octavesFromQ(band.bandwidth))
                    : String(format: "%.2f", band.bandwidth)
                paramRow(widthLabel, value: widthDisplay, unit: nil) { dragged in
                    update(band: band) {
                        $0.bandwidth = max(0.1, min(10, $0.bandwidth + Double(dragged) * 0.02))
                    }
                }

                Spacer()

                Button(role: .destructive) {
                    removeBand(band)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove selected band")
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))
            )
        } else if activeBands.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This ear has no bands yet")
                        .font(.callout.weight(.medium))
                    Text("Quick start places 8 disabled parametric bands at the audiogram frequencies, ready for you to enable and tune.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    quickStart()
                } label: {
                    Label("Quick start: 8 bands", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.08))
            )
        } else {
            HStack {
                Image(systemName: "hand.point.up.left.fill").foregroundStyle(.secondary)
                Text("Drag a node on the curve to edit it, or **Add band** above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.06))
            )
        }
    }

    /// Populate the active ear (and the other, when linked) with 8 disabled
    /// parametric bands at the standard audiogram frequencies. Each band
    /// starts at 0 dB / Q 1, ready to enable and tune.
    private func quickStart() {
        guard var profile = activeProfile else { return }
        let seed = Self.quickStartFrequencies.map { freq in
            EQBand(frequencyHz: freq, gaindB: 0, bandwidth: 1.0, filterType: .parametric, enabled: true)
        }
        if tab == .left { profile.leftEar.bands = seed }
        else { profile.rightEar.bands = seed }
        if linkChannels {
            if tab == .left { profile.rightEar.bands = seed }
            else { profile.leftEar.bands = seed }
        }
        try? profileStore.save(profile)
    }

    /// Bottom-of-screen keyboard cheat sheet. Expert is the power-
    /// user tab — the shortcuts are real and load-bearing, but
    /// discovering them by reading the source isn't a workflow. Pin
    /// the legend to the page so they're visible while you're using
    /// the tab. Compact 2-column grid with monospaced keycap glyphs
    /// to read as keys rather than running text.
    @ViewBuilder private var shortcutsKey: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .foregroundStyle(.secondary)
                Text("Keyboard shortcuts")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            // Two columns of rows so 8 entries fit without scrolling.
            // Grid lines up keycaps in their own column so the eye
            // can scan straight down the list.
            Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow {
                    shortcutEntry(keys: ["Tab"], alt: ["L"], label: "Next band")
                    shortcutEntry(keys: ["␣"], alt: nil, label: "Toggle band on / off")
                }
                GridRow {
                    shortcutEntry(keys: ["J"], alt: nil, label: "Previous band")
                    shortcutEntry(keys: ["↩"], alt: nil, label: "Reset gain to 0")
                }
                GridRow {
                    shortcutEntry(keys: ["↑", "↓"], alt: nil,
                                  label: "Gain ±1 dB",
                                  modifiers: "Shift ±0.5 · ⌘ ±5 · ⌘⇧ ±0.1")
                    shortcutEntry(keys: ["⌫"], alt: nil, label: "Remove band")
                }
                GridRow {
                    shortcutEntry(keys: ["←", "→"], alt: nil,
                                  label: "Frequency ±5 %",
                                  modifiers: "Shift ±15 % · ⌘ ±50 % · ⌘⇧ ±1 Hz")
                    shortcutEntry(keys: ["[", "]"], alt: nil, label: "Q tighter / wider")
                }
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One shortcut entry: a row of monospaced keycaps + a short label
    /// + an optional second line of modifier hints (e.g. Shift / ⌘
    /// behaviour on the arrows).
    @ViewBuilder
    private func shortcutEntry(
        keys: [String],
        alt: [String]?,
        label: String,
        modifiers: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { keycap($0) }
                if let alt {
                    Text("or").font(.caption2).foregroundStyle(.tertiary)
                    ForEach(alt, id: \.self) { keycap($0) }
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let modifiers {
                    Text(modifiers)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 0.5)
            )
    }

    private func paramRow<V>(
        _ label: String,
        value: V,
        unit: String?,
        onDelta: @escaping (Float) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text("\(String(describing: value))")
                    .font(.callout.monospaced())
                if let unit { Text(unit).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .frame(width: 70, alignment: .leading)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    onDelta(Float(value.translation.height) * -1)
                }
        )
    }

    // MARK: - Helpers

    private var activeProfile: HearingProfile? {
        audioState.activeProfile(in: profileStore)
    }

    private var activeBands: [EQBand] {
        guard let profile = activeProfile else { return [] }
        return tab == .left ? profile.leftEar.bands : profile.rightEar.bands
    }

    private var earColor: Color { tab == .left ? audioState.leftEarColor : audioState.rightEarColor }
    private var shadowColor: Color { tab == .left ? audioState.rightEarColor : audioState.leftEarColor }

    private func shadowBands(for profile: HearingProfile) -> [EQBand] {
        tab == .left ? profile.rightEar.bands : profile.leftEar.bands
    }

    /// Compact "Δ vs target" readout shown next to the Gain field when an
    /// audiogram-derived target exists for this ear. Compares the user's
    /// COMPOSITE curve at the selected band's frequency to the target's
    /// composite curve — composite (not per-band gain) because adjacent
    /// bands' skirts contribute to the response at any single point.
    /// Hidden when the audiogram is flat or has no actionable thresholds.
    @ViewBuilder
    private func targetDeltaReadout(for band: EQBand, profile: HearingProfile) -> some View {
        let target = targetBands(for: profile)
        if !target.isEmpty && showAudiogramLayer {
            let userDB = BiquadResponse.compositeMagnitudeDB(at: band.frequencyHz, bands: activeBands)
            let targetDB = BiquadResponse.compositeMagnitudeDB(at: band.frequencyHz, bands: target)
            let delta = userDB - targetDB
            VStack(alignment: .leading, spacing: 1) {
                Text("vs target")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(formatDelta(delta))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(deltaTint(delta))
            }
            .frame(width: 78, alignment: .leading)
            .help("How far your active EQ is from the audiogram-derived target at \(Int(band.frequencyHz)) Hz. Drag Gain (or other bands) to close the gap.")
        }
    }

    private func formatDelta(_ dB: Double) -> String {
        let abs = Swift.abs(dB)
        if abs < 0.05 { return "± 0.0 dB" }
        return String(format: "%@%.1f dB", dB > 0 ? "+" : "−", abs)
    }

    private func deltaTint(_ dB: Double) -> Color {
        let abs = Swift.abs(dB)
        if abs < 1 { return .green }
        if abs < 3 { return .yellow }
        return .orange
    }

    /// Audiogram-derived "target" correction bands for the active ear.
    /// Computed from the profile's stored thresholds and the user's
    /// compensation factor — this is what the user's EQ "should" look
    /// like if they were tracking the audiogram cleanly. Empty when the
    /// audiogram is flat (no derived bands) so the canvas hides the layer.
    private func targetBands(for profile: HearingProfile) -> [EQBand] {
        let thresholds = tab == .left ? profile.leftEar.thresholds : profile.rightEar.thresholds
        return AudiogramConversion.bands(
            for: thresholds,
            compensationFactor: profile.compensationFactor
        )
    }

    private func bandsBinding(for profile: HearingProfile) -> Binding<[EQBand]> {
        Binding(
            get: { tab == .left ? profile.leftEar.bands : profile.rightEar.bands },
            set: { newBands in
                var updated = profile
                if tab == .left { updated.leftEar.bands = newBands }
                else { updated.rightEar.bands = newBands }
                if linkChannels {
                    // Mirror to the other ear, preserving each band's identity
                    // by frequency match (so the canvas's selectedBandID still
                    // works after the round-trip).
                    let other = (tab == .left ? updated.rightEar.bands : updated.leftEar.bands)
                    let mirrored = Self.mirrorBands(newBands, ontoExisting: other)
                    if tab == .left { updated.rightEar.bands = mirrored }
                    else { updated.leftEar.bands = mirrored }
                }
                try? profileStore.save(updated)
            }
        )
    }

    /// When linking ears, we propagate freq/gain/Q/type/enabled from the
    /// edited side onto the other, but keep the other side's band IDs (and
    /// any bands it has that the edited side doesn't, by index).
    private static func mirrorBands(_ source: [EQBand], ontoExisting target: [EQBand]) -> [EQBand] {
        var result = target
        for (i, src) in source.enumerated() {
            if i < result.count {
                result[i].frequencyHz = src.frequencyHz
                result[i].gaindB = src.gaindB
                result[i].bandwidth = src.bandwidth
                result[i].filterType = src.filterType
                result[i].enabled = src.enabled
            } else {
                result.append(src)
            }
        }
        if result.count > source.count {
            result.removeLast(result.count - source.count)
        }
        return result
    }

    private func enabledBinding(for band: EQBand) -> Binding<Bool> {
        Binding(
            get: { band.enabled },
            set: { newValue in update(band: band) { $0.enabled = newValue } }
        )
    }

    private func update(band: EQBand, _ mutate: (inout EQBand) -> Void) {
        guard var profile = activeProfile else { return }
        var bands = tab == .left ? profile.leftEar.bands : profile.rightEar.bands
        guard let idx = bands.firstIndex(where: { $0.id == band.id }) else { return }
        mutate(&bands[idx])
        if tab == .left { profile.leftEar.bands = bands } else { profile.rightEar.bands = bands }
        if linkChannels {
            let other = (tab == .left ? profile.rightEar.bands : profile.leftEar.bands)
            let mirrored = Self.mirrorBands(bands, ontoExisting: other)
            if tab == .left { profile.rightEar.bands = mirrored }
            else { profile.leftEar.bands = mirrored }
        }
        try? profileStore.save(profile)
    }

    private func setType(for band: EQBand, to type: EQFilterType) {
        update(band: band) { $0.filterType = type }
    }

    private func addBand() {
        guard var profile = activeProfile else { return }
        let new = EQBand(
            frequencyHz: 1000,
            gaindB: 0,
            bandwidth: 1.0,
            filterType: .parametric,
            enabled: true
        )
        if tab == .left { profile.leftEar.bands.append(new) }
        else { profile.rightEar.bands.append(new) }
        try? profileStore.save(profile)
        selectedBandID = new.id
    }

    private func removeBand(_ band: EQBand) {
        guard var profile = activeProfile else { return }
        if tab == .left { profile.leftEar.bands.removeAll { $0.id == band.id } }
        else { profile.rightEar.bands.removeAll { $0.id == band.id } }
        try? profileStore.save(profile)
        selectedBandID = nil
    }

    private func filterTypeLabel(_ t: EQFilterType) -> String {
        switch t {
        case .parametric: return "Parametric"
        case .lowShelf:   return "Low shelf"
        case .highShelf:  return "High shelf"
        case .notch:      return "Notch"
        case .bandPass:   return "Band-pass"
        case .lowPass:    return "Low-pass"
        case .highPass:   return "High-pass"
        }
    }

    private func clampHz(_ v: Double) -> Double { max(20, min(20_000, v)) }
    private func clampDB(_ v: Double) -> Double { max(-24, min(24, v)) }

    /// Q → equivalent bandwidth in octaves (Audio EQ Cookbook formula).
    static func octavesFromQ(_ q: Double) -> Double {
        guard q > 0 else { return 0 }
        return (2.0 / log(2.0)) * asinh(1.0 / (2.0 * q))
    }
}
