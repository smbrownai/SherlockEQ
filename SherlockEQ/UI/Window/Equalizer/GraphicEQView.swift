import SwiftUI

/// 12-band graphic EQ — vertical sliders on the audiometric grid (the
/// octave series plus 3 kHz and 6 kHz, so the graphic surface speaks the
/// same frequencies as the audiogram). Like Simple, it shares the
/// underlying band array with the other tabs.
struct GraphicEQView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var audioState: AudioState

    /// Canonical center list lives on `EQMode` so the slider row and the
    /// mode's `ownedSlots` (hidden-bands accounting) can't drift apart.
    private static let frequencies: [Double] = EQMode.graphicCenters
    private static let bandwidth: Double = 1.0   // 1 octave Q

    /// Reads the active profile's `separateChannels` flag. Toggle
    /// lives on Profile Detail. Default for new profiles is false
    /// (linked).
    private var linkChannels: Bool {
        !(audioState.activeProfile(in: profileStore)?.separateChannels ?? false)
    }

    // Spectrum-overlay layer visibility — shares Expert's @AppStorage keys
    // so the user's chip preference is consistent across modes.
    @AppStorage("sherlockeq.layer.output")    private var showOutputLayer    = true
    @AppStorage("sherlockeq.layer.input")     private var showInputLayer     = true
    // Result is the default-visible hero. The EQ-only and Correction traces
    // are the breakdown, off until the user picks them.
    @AppStorage("sherlockeq.layer.result")    private var showResultLayer    = true
    @AppStorage("sherlockeq.layer.eq")        private var showEQLayer        = false
    @AppStorage("sherlockeq.layer.audiogram") private var showAudiogramLayer = false
    @AppStorage("sherlockeq.layer.safety")    private var showSafetyLayer    = false

    var body: some View {
        if let profile = audioState.activeProfile(in: profileStore) {
            content(profile)
        } else {
            ContentUnavailableView(
                "No active profile",
                systemImage: "slider.vertical.3",
                description: Text("Make a profile active to use the Graphic EQ.")
            )
        }
    }

    @ViewBuilder private func content(_ profile: HearingProfile) -> some View {
        // Per-ear hearing correction (what's actually applied). The audiogram
        // is inherently per-ear, so we surface both even when EQ is linked.
        let leftCorrection = profile.leftEar.correctionBands
        let rightCorrection = profile.rightEar.correctionBands
        let hasAudiogram = !leftCorrection.isEmpty || !rightCorrection.isEmpty
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                topBar
                CanvasLayerChipStrip(
                    showInputSpectrum: $showInputLayer,
                    showOutputSpectrum: $showOutputLayer,
                    showEQCurve: $showEQLayer,
                    showAudiogramTarget: $showAudiogramLayer,
                    showResultCurve: $showResultLayer,
                    showSafetyOverlay: $showSafetyLayer,
                    // Dynamic-feature overlay is an Expert-canvas affordance
                    // (live node semantics); the graphic-EQ canvas hides it.
                    showDynamics: .constant(false),
                    hasAudiogram: hasAudiogram,
                    hasDynamics: false,
                    earColor: audioState.preferences.leftEarColor
                )
                previewCanvas(profile, leftCorrection: leftCorrection, rightCorrection: rightCorrection)
                // Between curve and sliders (spec §1.4): the row explains
                // that the curve ABOVE includes filters the sliders BELOW
                // can't represent — its copy depends on this position.
                otherFiltersRow(profile)
                slidersRow(profile)
                resetButton(profile)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            presetMenu
            Spacer()
        }
    }

    /// One-click curated curves shaped to the 10 octave bands. Mirrors
    /// the Speech and Simple preset menus so the affordance reads as
    /// consistent across tabs. Each preset overwrites the graphic
    /// bands on both ears; other tabs' bands stay untouched.
    private var presetMenu: some View {
        Menu {
            ForEach(GraphicEQPreset.allCases) { preset in
                Button {
                    apply(preset)
                } label: {
                    VStack(alignment: .leading) {
                        Label(preset.label, systemImage: preset.symbol)
                        Text(preset.tagline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("\(preset.label) preset. \(preset.tagline)")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tint)
                Text("Preset")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tint)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentColor.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("One-click curated curves for the graphic bands.")
        .accessibilityLabel("Graphic EQ preset")
    }

    private func apply(_ preset: GraphicEQPreset) {
        guard let profile = audioState.activeProfile(in: profileStore) else { return }
        var updated = profile
        EQBandLookup.mutateBothEars(of: &updated) { bands in
            for freq in Self.frequencies {
                let gain = preset.gain(forHz: freq)
                EQBandLookup.setGain(gain, at: freq, bandwidth: Self.bandwidth, filterType: .parametric, in: &bands)
            }
        }
        try? profileStore.save(updated)
    }

    // MARK: - Other filters (the "nothing invisible" invariant)

    /// Bands the graphic sliders can't represent — anything off the 12-slot
    /// grid (filters from the retired Simple/Speech modes, Parametric-
    /// authored bands, CLI `simple-eq` writes). The response curve above
    /// already draws them (it renders the full band array), so the curve is
    /// honest; this row makes sure the *controls* story is honest too:
    /// convert them onto the sliders, or edit them where they live. See
    /// phase3-make-correction-land.md §1.4.
    @ViewBuilder private func otherFiltersRow(_ profile: HearingProfile) -> some View {
        let leftHidden = audiblyContributing(EQMode.advanced.hiddenBands(in: profile.leftEar.bands))
        let rightHidden = audiblyContributing(EQMode.advanced.hiddenBands(in: profile.rightEar.bands))
        let count = max(leftHidden.count, rightHidden.count)
        if count > 0 {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "slider.horizontal.2.square.on.square")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count) other filter\(count == 1 ? "" : "s") active")
                        .font(.callout.weight(.semibold))
                    Text("Filters not on these sliders — from Parametric, an older mode, or the command line. The curve above includes them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Convert to Graphic") {
                    convertOtherFilters(profile)
                }
                .help("Approximate these filters on the 12 sliders and remove the originals. One undo step.")
                Button("Edit in Parametric") {
                    var updated = profile
                    updated.eqMode = .expert
                    try? profileStore.save(updated, actionName: "Switch to Parametric")
                }
                .help("Switch this profile to the Parametric surface, where every filter is editable directly.")
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.orange.opacity(0.35))
            )
            .accessibilityElement(children: .combine)
        }
    }

    /// The invariant is about *audible* processing: an off-grid band that
    /// contributes nothing (disabled, or a gain-driven type sitting at
    /// 0 dB — e.g. residue from the CLI's `simple-eq … 0`) doesn't warrant
    /// the row. Gain-independent types (notch / band-pass / low-pass /
    /// high-pass) always shape the signal while enabled, whatever their
    /// gain field says.
    private func audiblyContributing(_ bands: [EQBand]) -> [EQBand] {
        bands.filter { band in
            guard band.enabled else { return false }
            switch band.filterType {
            case .parametric, .lowShelf, .highShelf:
                return band.gaindB != 0
            case .notch, .bandPass, .lowPass, .highPass:
                return true
            }
        }
    }

    /// Fold the off-grid filters into the graphic sliders (per ear) and
    /// remove the originals. Additive in dB — cascade magnitudes sum — so
    /// fitting the off-grid bands alone and adding onto the current slider
    /// gains preserves the total curve up to the fit's approximation error.
    /// Inert off-grid bands (disabled / 0-gain) contribute nothing to the
    /// fit and are simply removed as cleanup.
    private func convertOtherFilters(_ profile: HearingProfile) {
        var updated = profile
        for ear in [\HearingProfile.leftEar, \HearingProfile.rightEar] {
            let hidden = EQMode.advanced.hiddenBands(in: updated[keyPath: ear].bands)
            guard !hidden.isEmpty else { continue }
            let fitted = GraphicConversion.fittedGains(for: hidden.filter(\.enabled))

            let hiddenIDs = Set(hidden.map(\.id))
            updated[keyPath: ear].bands.removeAll { hiddenIDs.contains($0.id) }

            for (center, gain) in zip(EQMode.graphicCenters, fitted) where gain != 0 {
                let current = EQBandLookup.gain(
                    at: center, filterType: .parametric,
                    in: updated[keyPath: ear].bands
                )
                let merged = min(GraphicConversion.sliderRangeDB.upperBound,
                                 max(GraphicConversion.sliderRangeDB.lowerBound, current + gain))
                EQBandLookup.setGain(
                    merged, at: center, bandwidth: Self.bandwidth,
                    filterType: .parametric, in: &updated[keyPath: ear].bands
                )
            }
        }
        try? profileStore.save(updated, actionName: "Convert filters to Graphic EQ")
    }

    @State private var dummySelection: UUID? = nil

    @ViewBuilder
    private func previewCanvas(_ profile: HearingProfile, leftCorrection: [EQBand], rightCorrection: [EQBand]) -> some View {
        LiveParametricCanvas(
            spectrum: audioState.spectrum,
            preSpectrum: audioState.preSpectrum,
            bands: .constant(profile.leftEar.bands),
            shadowBands: profile.rightEar.bands,
            targetBands: leftCorrection,
            shadowTargetBands: rightCorrection,
            notch: profile.leftNotch,
            shadowNotch: profile.rightNotch,
            spectrumSampleRate: audioState.audio.outputSampleRate ?? 48_000,
            earColor: audioState.preferences.leftEarColor,
            shadowColor: audioState.preferences.rightEarColor,
            readOnly: true,
            selectedBandID: $dummySelection,
            showInputSpectrum: showInputLayer,
            showOutputSpectrum: showOutputLayer,
            showEQCurve: showEQLayer,
            showAudiogramTarget: showAudiogramLayer,
            showResultCurve: showResultLayer,
            showSafetyOverlay: showSafetyLayer,
            safetyCeilingDBA: profile.safeListeningCeilingDB,
            calibrationOffsetDBA: audioState.effectiveCalibrationOffsetDBA
        )
        .frame(height: 180)
    }

    @ViewBuilder
    private func slidersRow(_ profile: HearingProfile) -> some View {
        // Spacing 4 (was 6): twelve 60 pt columns + 11 gaps + row padding
        // = 788 pt, which fits the detail column even at the minimum
        // window width with the monitor sidebar visible and the nav
        // sidebar dragged to its 300 pt maximum (~806 pt available).
        HStack(alignment: .top, spacing: 4) {
            ForEach(Array(Self.frequencies.enumerated()), id: \.offset) { _, freq in
                bandColumn(profile: profile, frequency: freq)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    /// Fixed column width regardless of channel mode. Two narrow sliders
    /// (28+4+28 = 60) or one centered wide slider both fit inside the same
    /// envelope, so toggling Link doesn't reflow the whole row.
    private static let columnWidth: CGFloat = 60

    @ViewBuilder
    private func bandColumn(profile: HearingProfile, frequency: Double) -> some View {
        VStack(spacing: 6) {
            chipRow(profile: profile, frequency: frequency)

            HStack(spacing: 4) {
                if linkChannels {
                    VerticalGainSlider(
                        value: gainBinding(profile: profile, frequency: frequency, ear: .left),
                        range: -12...12,
                        tint: audioState.preferences.leftEarColor,
                        accessibilityLabel: "\(formatFreq(frequency)) hertz, both ears"
                    )
                    .frame(width: 40)
                } else {
                    VerticalGainSlider(
                        value: gainBinding(profile: profile, frequency: frequency, ear: .left),
                        range: -12...12,
                        tint: audioState.preferences.leftEarColor,
                        accessibilityLabel: "\(formatFreq(frequency)) hertz, left ear"
                    )
                    .frame(width: 26)
                    VerticalGainSlider(
                        value: gainBinding(profile: profile, frequency: frequency, ear: .right),
                        range: -12...12,
                        tint: audioState.preferences.rightEarColor,
                        accessibilityLabel: "\(formatFreq(frequency)) hertz, right ear"
                    )
                    .frame(width: 26)
                }
            }
            .frame(width: Self.columnWidth, height: 220)

            Text(formatFreq(frequency))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func chipRow(profile: HearingProfile, frequency: Double) -> some View {
        HStack(spacing: 4) {
            if linkChannels {
                EQGainChip(
                    value: gainBinding(profile: profile, frequency: frequency, ear: .left),
                    range: -12...12,
                    tint: audioState.preferences.leftEarColor,
                    accessibilityLabel: "\(formatFreq(frequency)) hertz, both ears, gain"
                )
                .frame(width: 40)
            } else {
                EQGainChip(
                    value: gainBinding(profile: profile, frequency: frequency, ear: .left),
                    range: -12...12,
                    tint: audioState.preferences.leftEarColor,
                    accessibilityLabel: "\(formatFreq(frequency)) hertz, left ear, gain"
                )
                .frame(width: 26)
                EQGainChip(
                    value: gainBinding(profile: profile, frequency: frequency, ear: .right),
                    range: -12...12,
                    tint: audioState.preferences.rightEarColor,
                    accessibilityLabel: "\(formatFreq(frequency)) hertz, right ear, gain"
                )
                .frame(width: 26)
            }
        }
        .frame(width: Self.columnWidth)
    }

    private typealias Ear = EQBandLookup.Ear

    private func resetButton(_ profile: HearingProfile) -> some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                reset(profile)
            } label: {
                Label("Flatten Graphic bands", systemImage: "arrow.counterclockwise")
            }
        }
    }

    // MARK: - Binding helpers

    private func gainBinding(profile: HearingProfile, frequency: Double, ear: Ear) -> Binding<Double> {
        Binding(
            get: { gain(profile: profile, frequency: frequency, ear: ear) },
            set: { newValue in setGain(newValue, profile: profile, frequency: frequency, ear: ear) }
        )
    }

    private func gain(profile: HearingProfile, frequency: Double, ear: Ear) -> Double {
        switch ear {
        case .left:  return EQBandLookup.gain(at: frequency, filterType: .parametric, in: profile.leftEar.bands)
        case .right: return EQBandLookup.gain(at: frequency, filterType: .parametric, in: profile.rightEar.bands)
        }
    }

    private func setGain(_ gain: Double, profile: HearingProfile, frequency: Double, ear: Ear) {
        var updated = profile
        EQBandLookup.mutateBands(of: &updated, ear: ear, linkChannels: linkChannels) { bands in
            EQBandLookup.setGain(gain, at: frequency, bandwidth: Self.bandwidth, filterType: .parametric, in: &bands)
        }
        try? profileStore.save(updated, actionName: "Adjust \(formatFreq(frequency))")
    }

    private func reset(_ profile: HearingProfile) {
        var updated = profile
        EQBandLookup.mutateBothEars(of: &updated) { bands in
            for freq in Self.frequencies {
                EQBandLookup.setGain(0, at: freq, bandwidth: Self.bandwidth, filterType: .parametric, in: &bands)
            }
        }
        try? profileStore.save(updated)
    }

    private func formatFreq(_ hz: Double) -> String {
        if hz >= 1000 {
            let k = hz / 1000
            return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return "\(Int(hz))"
    }
}

/// Substantial vertical gain slider — the column itself is the hit target.
/// A rounded track sits behind, the colored fill animates between the value
/// and the 0 dB center line, a tick marks the zero, and the handle is a
/// chunky pill the user can grab anywhere on the column.
private struct VerticalGainSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var tint: Color = .blue
    /// VoiceOver / focus label. Caller supplies the band's frequency
    /// + ear ("1 kHz, left ear"); the slider exposes the dB value
    /// itself via `.accessibilityValue`.
    var accessibilityLabel: String = "Gain"

    var body: some View {
        GeometryReader { geo in
            let zeroY = yFor(0, height: geo.size.height)
            let valueY = yFor(clampedValue, height: geo.size.height)

            ZStack {
                // Track
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 8)

                // Tick marks at every 0.5 dB across the full range.
                // Integer dB values get a slightly wider, more opaque
                // tick so the eye can still find whole numbers; the
                // 0.5 mid-marks read as finer hairlines beside them.
                // Drawn via Canvas (one draw call instead of N
                // Rectangles) since there are 49 ticks per slider and
                // 10–20 sliders on screen.
                ticksCanvas(size: geo.size)

                // Fill between value and zero
                Capsule()
                    .fill(tint.opacity(0.55))
                    .frame(width: 8, height: abs(valueY - zeroY))
                    .position(
                        x: geo.size.width / 2,
                        y: (valueY + zeroY) / 2
                    )

                // 0 dB tick — full-width emphasis above the per-0.5
                // tick ladder so center reference stays unambiguous.
                Rectangle()
                    .fill(Color.primary.opacity(0.45))
                    .frame(width: geo.size.width * 0.85, height: 1)
                    .position(x: geo.size.width / 2, y: zeroY)

                // Handle
                Capsule()
                    .fill(tint)
                    .overlay(
                        Capsule().stroke(Color.white.opacity(0.85), lineWidth: 1)
                    )
                    .frame(width: geo.size.width * 0.85, height: 12)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .position(x: geo.size.width / 2, y: valueY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let y = max(0, min(geo.size.height, gesture.location.y))
                        let normalized = 1 - Double(y / geo.size.height)
                        var newValue = range.lowerBound + normalized * (range.upperBound - range.lowerBound)
                        // 0.1 dB drag resolution — fine enough for
                        // careful tonal adjustment without the slider
                        // feeling stick-slip noisy. The on-screen
                        // readout still rounds to 1 decimal place,
                        // so the displayed value matches the stored
                        // value exactly.
                        newValue = (newValue * 10).rounded() / 10
                        value = max(range.lowerBound, min(range.upperBound, newValue))
                    }
            )
            // Accessibility: arrow keys / VO swipes nudge ±0.5 dB
            // (matches the on-screen tick spacing — the major ticks
            // sit every 0.5 dB). Custom drag-only control was
            // entirely unreachable without a pointing device before.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(String(format: "%+.1f dB", clampedValue))
            .accessibilityAdjustableAction { direction in
                let step = 0.5
                let target: Double
                switch direction {
                case .increment: target = value + step
                case .decrement: target = value - step
                @unknown default: return
                }
                value = max(range.lowerBound, min(range.upperBound, (target * 10).rounded() / 10))
            }
        }
    }

    @ViewBuilder
    private func ticksCanvas(size: CGSize) -> some View {
        let halfTrackWidth: CGFloat = 5   // a bit outside the 8 pt track
        let majorLength: CGFloat = 5
        let minorLength: CGFloat = 3
        let majorOpacity: Double = 0.40
        let minorOpacity: Double = 0.22
        // Generate the half-dB tick values inside the range, skipping
        // 0 (the dedicated full-width 0 dB tick handles that).
        let lo = range.lowerBound
        let hi = range.upperBound
        // Multiply by 2 + integer stride to avoid floating-point drift.
        let firstHalf = Int((lo * 2).rounded(.up))
        let lastHalf  = Int((hi * 2).rounded(.down))
        Canvas { context, canvasSize in
            for halfStep in firstHalf...lastHalf {
                let db = Double(halfStep) / 2
                if db == 0 { continue }
                let isMajor = halfStep % 2 == 0
                let length = isMajor ? majorLength : minorLength
                let opacity = isMajor ? majorOpacity : minorOpacity
                let y = yFor(db, height: canvasSize.height)
                let centerX = canvasSize.width / 2
                var path = Path()
                path.move(to: CGPoint(x: centerX - halfTrackWidth - length, y: y))
                path.addLine(to: CGPoint(x: centerX - halfTrackWidth, y: y))
                path.move(to: CGPoint(x: centerX + halfTrackWidth, y: y))
                path.addLine(to: CGPoint(x: centerX + halfTrackWidth + length, y: y))
                context.stroke(path, with: .color(Color.secondary.opacity(opacity)), lineWidth: 1)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private var clampedValue: Double {
        max(range.lowerBound, min(range.upperBound, value))
    }

    private func yFor(_ db: Double, height: CGFloat) -> CGFloat {
        let normalized = (range.upperBound - db) / (range.upperBound - range.lowerBound)
        return CGFloat(normalized) * height
    }
}

// MARK: - Graphic presets

/// Curated starting points for the Graphic EQ. Each preset
/// lists per-band dB offsets keyed by the band's centre frequency
/// (Hz). Bands not in `gains` get 0 (flat / removed from the chain) —
/// which is also how the presets behave on the 12-band grid's 3 kHz /
/// 6 kHz slots until the §3 re-voicing gives them explicit values.
enum GraphicEQPreset: String, CaseIterable, Identifiable {
    case flat
    case loudness
    case warm
    case bright
    case vShape
    case classical
    case acoustic
    case country
    case jazz
    case rock
    case hipHop
    case electronic
    case techno
    case trebleTame
    case bassRoll

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flat:       return "Flat"
        case .loudness:   return "Loudness compensation"
        case .warm:       return "Warm"
        case .bright:     return "Bright"
        case .vShape:     return "V-shape"
        case .classical:  return "Classical"
        case .acoustic:   return "Acoustic"
        case .country:    return "Country"
        case .jazz:       return "Jazz"
        case .rock:       return "Rock"
        case .hipHop:     return "Hip-hop / R&B"
        case .electronic: return "Electronic"
        case .techno:     return "Techno"
        case .trebleTame: return "Treble tame"
        case .bassRoll:   return "Bass rolloff"
        }
    }

    var symbol: String {
        switch self {
        case .flat:       return "minus"
        case .loudness:   return "speaker.wave.3"
        case .warm:       return "flame"
        case .bright:     return "sparkles"
        case .vShape:     return "chevron.up.chevron.down"
        case .classical:  return "pianokeys"
        case .acoustic:   return "music.quarternote.3"
        case .country:    return "music.mic"
        case .jazz:       return "music.note.list"
        case .rock:       return "guitars"
        case .hipHop:     return "waveform.path.ecg"
        case .electronic: return "waveform"
        case .techno:     return "waveform.circle"
        case .trebleTame: return "ear.trianglebadge.exclamationmark"
        case .bassRoll:   return "arrow.down.right"
        }
    }

    var tagline: String {
        switch self {
        case .flat:
            return "Reset all 10 bands to 0."
        case .loudness:
            return "Boosts low and high extremes — restores perceived balance at low listening volume (Fletcher-Munson)."
        case .warm:
            return "Bass-forward, gentle treble rolloff — easier on long sessions."
        case .bright:
            return "Treble emphasis with a slight low-mid cut — adds clarity and air."
        case .vShape:
            return "Boost the extremes, scoop the mids — modern consumer / club sound."
        case .classical:
            return "Trim rumble, gentle string and air lift — preserves the natural mid balance orchestras need."
        case .acoustic:
            return "Trim rumble, lift instrument body and string brilliance — fingerpicking and small-ensemble material."
        case .country:
            return "Warm vocal body and acoustic-instrument presence — vocal-forward without losing twang."
        case .jazz:
            return "Smooth mid warmth around horns and upright bass — mid-forward without spotlighting cymbals."
        case .rock:
            return "Mild bass body and a 2–4 kHz presence lift for guitar bite."
        case .hipHop:
            return "Sub-bass forward with a gentle low-mid scoop — kick drums and 808s hit harder."
        case .electronic:
            return "Wide synth shape — sub-bass body, scooped low-mids, shimmer on top."
        case .techno:
            return "Kick-forward bass body and crisp hi-hats — built for pumping four-on-the-floor."
        case .trebleTame:
            return "Progressive treble cut — useful for hyperacusis or sibilant material."
        case .bassRoll:
            return "Gentle low-frequency cut — tightens up small speakers and reduces room boom."
        }
    }

    func gain(forHz hz: Double) -> Double { gains[hz] ?? 0 }

    /// Keyed by band centre frequency — matches `GraphicEQView.frequencies`.
    var gains: [Double: Double] {
        switch self {
        case .flat:
            return [:]
        case .loudness:
            return [31.5: 6, 63: 5, 125: 3, 250: 1,
                    4000: 1, 8000: 3, 16000: 5]
        case .warm:
            return [31.5: 2, 63: 3, 125: 2, 250: 1,
                    2000: -1, 4000: -2, 8000: -2, 16000: -1]
        case .bright:
            return [125: -1, 250: -1,
                    2000: 1, 4000: 2, 8000: 3, 16000: 3]
        case .vShape:
            return [31.5: 3, 63: 3, 125: 2,
                    500: -2, 1000: -3, 2000: -2,
                    8000: 2, 16000: 3]
        case .classical:
            return [31.5: -2, 63: -1,
                    250: 1,
                    2000: 1, 4000: 1, 8000: 2, 16000: 1]
        case .acoustic:
            return [31.5: -2, 63: -1,
                    250: 1, 500: 1,
                    2000: 1, 4000: 1, 8000: 2, 16000: 1]
        case .country:
            return [31.5: -1,
                    125: 1, 250: 1, 500: 1, 1000: 1,
                    2000: 2, 4000: 1, 8000: 1]
        case .jazz:
            return [31.5: -2, 63: -1,
                    125: 1, 250: 1, 500: 2, 1000: 1,
                    2000: 1, 8000: 1]
        case .rock:
            return [31.5: 1, 63: 2, 125: 1,
                    500: -1,
                    2000: 2, 4000: 2, 8000: 1, 16000: 1]
        case .hipHop:
            return [31.5: 5, 63: 4, 125: 2,
                    500: -2, 1000: -1,
                    4000: 1, 8000: 2, 16000: 1]
        case .electronic:
            return [31.5: 3, 63: 3, 125: 1,
                    500: -2, 1000: -1,
                    4000: 1, 8000: 3, 16000: 2]
        case .techno:
            return [31.5: 4, 63: 4, 125: 2,
                    1000: -1,
                    4000: 1, 8000: 3, 16000: 3]
        case .trebleTame:
            return [2000: -1, 4000: -3, 8000: -5, 16000: -6]
        case .bassRoll:
            return [31.5: -6, 63: -4, 125: -2]
        }
    }
}
