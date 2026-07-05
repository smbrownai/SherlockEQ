import SwiftUI

/// Speech-clarity-focused view onto the same per-ear EQ bands that
/// Simple / Advanced / Expert edit. Six named sliders, each one mapped
/// to a single parametric (or shelf) band at a frequency that maps to
/// a real speech-perception band. Designed for users who don't know
/// what "2.5 kHz" means but absolutely know what "consonant clarity"
/// feels like when it's wrong.
///
/// Architecture mirrors `SimpleEQView` — bands live on `EarProfile.bands`,
/// `EQBandLookup` provides the find-or-create-by-frequency machinery,
/// and switching tabs in `EqualizerView` does not lose state.
struct SpeechEQView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var audioState: AudioState

    /// Specification for one Speech-mode band. The `frequencyHz`,
    /// `bandwidth`, and `filterType` together identify the band in the
    /// shared EQ chain (see `EQBandLookup`); the other fields drive the
    /// UI presentation. Adding a band means adding one entry here.
    struct SpeechBand: Hashable, Identifiable {
        let id: String
        let label: String
        let frequencyHz: Double
        let bandwidth: Double
        let filterType: EQFilterType
        let icon: String
        let help: String
    }

    /// Six bands chosen to span the speech-perception range, in order
    /// from low to high. Shelves are used at the extremes (low rumble,
    /// air & brilliance) so they shape entire regions rather than
    /// punching a peak; parametric peaks fill the middle where surgical
    /// adjustment matters more.
    static let speechBands: [SpeechBand] = [
        SpeechBand(
            id: "speech.rumble",
            label: "Low rumble",
            frequencyHz: 60,
            bandwidth: 0.707,
            filterType: .lowShelf,
            icon: "wind",
            help: "Traffic, HVAC, room boom, mic plosives. Cutting here often improves perceived clarity more than any treble boost — bass masks higher frequencies."
        ),
        SpeechBand(
            id: "speech.warmth",
            label: "Vocal warmth",
            frequencyHz: 200,
            bandwidth: 1.0,
            filterType: .parametric,
            icon: "person.wave.2",
            help: "Body and weight of voices — male fundamentals, lower female fundamentals. Too much sounds boomy or stuck in a barrel; too little sounds thin."
        ),
        SpeechBand(
            id: "speech.body",
            label: "Vocal body",
            frequencyHz: 800,
            bandwidth: 1.0,
            filterType: .parametric,
            icon: "waveform",
            help: "Fullness of vowels — where most speech energy lives. Cutting here makes voices feel hollow and distant."
        ),
        SpeechBand(
            id: "speech.clarity",
            label: "Consonant clarity",
            frequencyHz: 2500,
            bandwidth: 1.0,
            filterType: .parametric,
            icon: "text.bubble",
            help: "Definition of consonants — the biggest impact on intelligibility. Age-related hearing loss usually starts here, so a small boost often helps a lot."
        ),
        SpeechBand(
            id: "speech.sibilance",
            label: "Sibilance",
            frequencyHz: 6000,
            bandwidth: 1.5,
            filterType: .parametric,
            icon: "speaker.wave.3",
            help: "S, sh, ch, f sounds. Harsh and painful if too much; muddy and blurred if too little. Sensitive ears usually want a small cut."
        ),
        SpeechBand(
            id: "speech.air",
            label: "Air & brilliance",
            frequencyHz: 12000,
            bandwidth: 0.707,
            filterType: .highShelf,
            icon: "sparkles",
            help: "Breath sounds, room openness, naturalness. Less critical for understanding speech, more about how present and real voices feel."
        ),
    ]

    // MARK: - View state

    private typealias Ear = EQBandLookup.Ear

    /// Reads the active profile's `separateChannels` flag. Toggle
    /// lives on Profile Detail. Default for new profiles is false
    /// (linked).
    private var linkChannels: Bool {
        !(audioState.activeProfile(in: profileStore)?.separateChannels ?? false)
    }
    @AppStorage("sherlockeq.speech.showHelp") private var showHelp: Bool = true
    @State private var dummySelection: UUID? = nil

    var body: some View {
        if let profile = audioState.activeProfile(in: profileStore) {
            content(profile)
        } else {
            ContentUnavailableView(
                "No active profile",
                systemImage: "slider.horizontal.3",
                description: Text("Make a profile active to use the Speech EQ.")
            )
        }
    }

    @ViewBuilder
    private func content(_ profile: HearingProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                topBar
                HiddenBandsHintChip()
                previewCanvas(profile)
                if linkChannels {
                    bandColumn(for: profile, ear: .left, color: .accentColor, title: "Both ears")
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        bandColumn(for: profile, ear: .left, color: audioState.preferences.leftEarColor, title: "Left ear")
                        bandColumn(for: profile, ear: .right, color: audioState.preferences.rightEarColor, title: "Right ear")
                    }
                }
                resetButton(profile)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Sections

    private var topBar: some View {
        HStack(spacing: 12) {
            presetMenu
            Spacer()
            Toggle("Show help", isOn: $showHelp)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var presetMenu: some View {
        Menu {
            ForEach(SpeechPreset.allCases) { preset in
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
        .help("One-click presets tuned for common speech-listening scenarios.")
        .accessibilityLabel("Speech preset")
    }

    @ViewBuilder
    private func previewCanvas(_ profile: HearingProfile) -> some View {
        LiveParametricCanvas(
            spectrum: audioState.spectrum,
            preSpectrum: audioState.preSpectrum,
            bands: .constant(profile.leftEar.bands),
            shadowBands: profile.rightEar.bands,
            targetBands: profile.leftEar.correctionBands,
            shadowTargetBands: profile.rightEar.correctionBands,
            notch: profile.leftNotch,
            shadowNotch: profile.rightNotch,
            spectrumSampleRate: audioState.audio.outputSampleRate ?? 48_000,
            earColor: audioState.preferences.leftEarColor,
            shadowColor: audioState.preferences.rightEarColor,
            readOnly: true,
            selectedBandID: $dummySelection,
            // Toggle-less preview shows the Result ("what you hear") line —
            // EQ + hearing correction (identical to EQ when no audiogram).
            showEQCurve: false,
            showResultCurve: true
        )
        .frame(height: 200)
    }

    @ViewBuilder
    private func bandColumn(for profile: HearingProfile, ear: Ear, color: Color, title: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(title)
                    .font(.headline)
            }
            ForEach(Self.speechBands) { band in
                bandRow(profile: profile, ear: ear, band: band, color: color)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    @ViewBuilder
    private func bandRow(
        profile: HearingProfile,
        ear: Ear,
        band: SpeechBand,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: band.icon)
                    .foregroundStyle(color)
                    .frame(width: 22)
                Text(band.label)
                    .font(.callout.weight(.medium))
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(formatHz(band.frequencyHz))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatGain(currentGain(profile: profile, ear: ear, band: band)))
                    .font(.callout.monospaced().weight(.medium))
                    .frame(minWidth: 64, alignment: .trailing)
            }
            Slider(
                value: gainBinding(profile: profile, ear: ear, band: band),
                in: -12...12,
                step: 0.5
            )
            .tint(color)
            .controlSize(.large)
            if showHelp {
                Text(band.help)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func resetButton(_ profile: HearingProfile) -> some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                reset(profile)
            } label: {
                Label("Flatten Speech bands", systemImage: "arrow.counterclockwise")
            }
            .help("Removes the six bands per ear that the Speech sliders manage. Bands at other frequencies stay.")
        }
    }

    // MARK: - Bindings

    private func gainBinding(profile: HearingProfile, ear: Ear, band: SpeechBand) -> Binding<Double> {
        Binding(
            get: { currentGain(profile: profile, ear: ear, band: band) },
            set: { newValue in setGain(newValue, profile: profile, ear: ear, band: band) }
        )
    }

    private func currentGain(profile: HearingProfile, ear: Ear, band: SpeechBand) -> Double {
        let bands = ear == .left ? profile.leftEar.bands : profile.rightEar.bands
        return EQBandLookup.gain(at: band.frequencyHz, filterType: band.filterType, in: bands)
    }

    private func setGain(_ gain: Double, profile: HearingProfile, ear: Ear, band: SpeechBand) {
        var updated = profile
        EQBandLookup.mutateBands(of: &updated, ear: ear, linkChannels: linkChannels) { bands in
            EQBandLookup.setGain(gain, at: band.frequencyHz, bandwidth: band.bandwidth, filterType: band.filterType, in: &bands)
        }
        try? profileStore.save(updated, actionName: "Adjust \(band.label)")
    }

    // MARK: - Presets

    private func apply(_ preset: SpeechPreset) {
        guard let profile = audioState.activeProfile(in: profileStore) else { return }
        var updated = profile
        EQBandLookup.mutateBothEars(of: &updated) { bands in
            for band in Self.speechBands {
                let gain = preset.gain(for: band.id)
                EQBandLookup.setGain(gain, at: band.frequencyHz, bandwidth: band.bandwidth, filterType: band.filterType, in: &bands)
            }
        }
        try? profileStore.save(updated)
    }

    private func reset(_ profile: HearingProfile) {
        var updated = profile
        // Setting to 0 with our shelf/parametric spec causes EQBandLookup
        // to remove the band (its own contract for "flat = drop").
        EQBandLookup.mutateBothEars(of: &updated) { bands in
            for band in Self.speechBands {
                EQBandLookup.setGain(0, at: band.frequencyHz, bandwidth: band.bandwidth, filterType: band.filterType, in: &bands)
            }
        }
        try? profileStore.save(updated)
    }

    // MARK: - Formatting

    private func formatGain(_ db: Double) -> String {
        if abs(db) < 0.05 { return "± 0.0 dB" }
        return String(format: "%@%.1f dB", db > 0 ? "+" : "−", abs(db))
    }

    private func formatHz(_ hz: Double) -> String {
        if hz >= 1000 {
            let k = hz / 1000
            return k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
        }
        return "\(Int(hz)) Hz"
    }
}

// MARK: - Speech presets

/// Opinionated starting points for common speech-listening scenarios.
/// Each preset lists per-band dB offsets; applying overwrites whatever
/// the user had on those six bands (one-click semantics, easy to undo
/// via Flatten or another preset). Bands NOT in `gains` get 0.
enum SpeechPreset: String, CaseIterable, Identifiable {
    case flat, audiobook, podcast, tvDialogue, voiceCall, hearingAidLite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flat:           return "Flat"
        case .audiobook:      return "Audiobook"
        case .podcast:        return "Podcast"
        case .tvDialogue:     return "TV dialogue"
        case .voiceCall:      return "Voice call"
        case .hearingAidLite: return "Hearing-aid lite"
        }
    }

    var symbol: String {
        switch self {
        case .flat:           return "minus"
        case .audiobook:      return "book"
        case .podcast:        return "mic"
        case .tvDialogue:     return "tv"
        case .voiceCall:      return "phone"
        case .hearingAidLite: return "ear"
        }
    }

    var tagline: String {
        switch self {
        case .flat:
            return "Reset all six sliders to 0."
        case .audiobook:
            return "Long-form spoken word — slight warmth + clarity, easier on the ears."
        case .podcast:
            return "Compressed audio with variable mic quality — cut rumble, boost clarity."
        case .tvDialogue:
            return "TV mixes drown dialogue in score and SFX — cut rumble, lift clarity."
        case .voiceCall:
            return "Zoom / phone codecs strip helpful bands — restore clarity, tame harshness."
        case .hearingAidLite:
            return "Mild age-related hearing loss — emphasises consonants and sibilants."
        }
    }

    func gain(for bandID: String) -> Double {
        gains[bandID] ?? 0
    }

    var gains: [String: Double] {
        switch self {
        case .flat:
            return [:]
        case .audiobook:
            return [
                "speech.rumble":    -2,
                "speech.warmth":    +1,
                "speech.clarity":   +2,
                "speech.sibilance": -1,
            ]
        case .podcast:
            return [
                "speech.rumble":    -3,
                "speech.body":      +1,
                "speech.clarity":   +3,
                "speech.sibilance": -1,
            ]
        case .tvDialogue:
            return [
                "speech.rumble":    -4,
                "speech.body":      -1,
                "speech.clarity":   +4,
                "speech.sibilance": +1,
            ]
        case .voiceCall:
            return [
                "speech.rumble":    -5,
                "speech.clarity":   +5,
                "speech.sibilance": -2,
                "speech.air":       +1,
            ]
        case .hearingAidLite:
            return [
                "speech.rumble":    -2,
                "speech.clarity":   +4,
                "speech.sibilance": +2,
                "speech.air":       +2,
            ]
        }
    }
}
