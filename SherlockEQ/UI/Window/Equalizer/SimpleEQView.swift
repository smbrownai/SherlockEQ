import SwiftUI

/// 3-band Bass / Mids / Treble view onto the active profile. Each slider
/// edits a single wide parametric band centered at a representative
/// frequency; flat (0 dB) bands are removed so the engine slot can be
/// reused by other tabs. Mirrors the same per-ear bands as Advanced and
/// Expert — changes in any tab are reflected in the others.
struct SimpleEQView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var audioState: AudioState

    private struct SimpleBand: Hashable {
        let label: String
        let frequencyHz: Double
        let bandwidth: Double
        let filterType: EQFilterType
        let icon: String
        let help: String
    }

    /// Bass + Treble are shelves so adjusting them never stacks weirdly
    /// with Advanced or Expert's parametric peaks at the same frequencies
    /// — a shelf is a fundamentally different filter shape. Mids stays a
    /// parametric peak (no equivalent shelf for the middle region).
    private static let simpleBands: [SimpleBand] = [
        SimpleBand(
            label: "Bass",
            frequencyHz: 250,
            bandwidth: 0.707,
            filterType: .lowShelf,
            icon: "speaker.wave.2.fill",
            help: "Warmth and weight — kick drums, bass guitar, the foundation of male voices. Too much sounds boomy or muddy; too little sounds thin and tinny."
        ),
        SimpleBand(
            label: "Mids",
            frequencyHz: 1000,
            bandwidth: 1.8,
            filterType: .parametric,
            icon: "waveform",
            help: "The body of voices and most instruments — where almost all musical detail lives. Cutting here pushes everything back; boosting can sound boxy or honky."
        ),
        SimpleBand(
            label: "Treble",
            frequencyHz: 5000,
            bandwidth: 0.707,
            filterType: .highShelf,
            icon: "music.note",
            help: "Brightness and air — cymbals, sibilance, instrument detail. Too much sounds harsh or fatiguing; too little sounds dull and veiled."
        ),
    ]

    /// Reads the active profile's `separateChannels` flag (single
    /// column when false, per-ear columns when true). Profile Detail
    /// exposes the toggle. Default for new profiles is false.
    private var linkChannels: Bool {
        !(audioState.activeProfile(in: profileStore)?.separateChannels ?? false)
    }

    var body: some View {
        if let profile = audioState.activeProfile(in: profileStore) {
            content(profile)
        } else {
            ContentUnavailableView(
                "No active profile",
                systemImage: "slider.horizontal.3",
                description: Text("Make a profile active to use the Simple EQ.")
            )
        }
    }

    @ViewBuilder private func content(_ profile: HearingProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
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

    /// One-click curated curves — same visual treatment Speech uses so
    /// the affordance reads as familiar across tabs. Each preset
    /// overwrites the three Simple bands on both ears; other tabs'
    /// bands (Advanced peaks, Expert custom bands, AutoEQ, audiogram
    /// compensation) are untouched.
    private var presetMenu: some View {
        Menu {
            ForEach(SimpleEQPreset.allCases) { preset in
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
        .help("One-click curated curves for the three Simple bands.")
        .accessibilityLabel("Simple EQ preset")
    }

    private func apply(_ preset: SimpleEQPreset) {
        guard let profile = audioState.activeProfile(in: profileStore) else { return }
        var updated = profile
        EQBandLookup.mutateBothEars(of: &updated) { bands in
            for band in Self.simpleBands {
                let gain = preset.gain(forHz: band.frequencyHz)
                EQBandLookup.setGain(gain, at: band.frequencyHz, bandwidth: band.bandwidth, filterType: band.filterType, in: &bands)
            }
        }
        try? profileStore.save(updated)
    }

    @State private var dummySelection: UUID? = nil

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
            // This toggle-less preview shows the Result ("what you hear") line:
            // EQ summed with the hearing correction. With no audiogram the two
            // are identical, so this stays correct either way.
            showEQCurve: false,
            showResultCurve: true
        )
        .frame(height: 180)
    }

    private typealias Ear = EQBandLookup.Ear

    @ViewBuilder
    private func bandColumn(for profile: HearingProfile, ear: Ear, color: Color, title: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(title)
                    .font(.headline)
            }

            ForEach(Self.simpleBands, id: \.self) { band in
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
        band: SimpleBand,
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
                Text("\(Int(band.frequencyHz)) Hz")
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
            Text(band.help)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resetButton(_ profile: HearingProfile) -> some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                reset(profile)
            } label: {
                Label("Flatten Simple bands", systemImage: "arrow.counterclockwise")
            }
            .help("Removes the 3 bands per ear that the Simple sliders manage. Bands at other frequencies stay.")
        }
    }

    // MARK: - Bindings

    private func gainBinding(profile: HearingProfile, ear: Ear, band: SimpleBand) -> Binding<Double> {
        Binding(
            get: { currentGain(profile: profile, ear: ear, band: band) },
            set: { newValue in setGain(newValue, profile: profile, ear: ear, band: band) }
        )
    }

    private func currentGain(profile: HearingProfile, ear: Ear, band: SimpleBand) -> Double {
        let bands = ear == .left ? profile.leftEar.bands : profile.rightEar.bands
        return EQBandLookup.gain(at: band.frequencyHz, filterType: band.filterType, in: bands)
    }

    private func setGain(_ gain: Double, profile: HearingProfile, ear: Ear, band: SimpleBand) {
        var updated = profile
        EQBandLookup.mutateBands(of: &updated, ear: ear, linkChannels: linkChannels) { bands in
            EQBandLookup.setGain(gain, at: band.frequencyHz, bandwidth: band.bandwidth, filterType: band.filterType, in: &bands)
        }
        try? profileStore.save(updated, actionName: "Adjust \(band.label)")
    }

    private func reset(_ profile: HearingProfile) {
        var updated = profile
        EQBandLookup.mutateBothEars(of: &updated) { bands in
            for band in Self.simpleBands {
                EQBandLookup.setGain(0, at: band.frequencyHz, bandwidth: band.bandwidth, filterType: band.filterType, in: &bands)
            }
        }
        try? profileStore.save(updated)
    }

    private func formatGain(_ db: Double) -> String {
        if abs(db) < 0.05 { return "0 dB" }
        return String(format: "%+.1f dB", db)
    }
}

// MARK: - Simple presets

/// Curated starting points for the 3-band Simple EQ. Each preset
/// lists per-band dB offsets keyed by the band's centre frequency.
/// Bands not in `gains` get 0 (flat / removed from the chain).
enum SimpleEQPreset: String, CaseIterable, Identifiable {
    case flat
    case loudness
    case warm
    case bright
    case vocalForward
    case trebleTame

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flat:         return "Flat"
        case .loudness:     return "Loudness compensation"
        case .warm:         return "Warm"
        case .bright:       return "Bright"
        case .vocalForward: return "Vocal forward"
        case .trebleTame:   return "Treble tame"
        }
    }

    var symbol: String {
        switch self {
        case .flat:         return "minus"
        case .loudness:     return "speaker.wave.3"
        case .warm:         return "flame"
        case .bright:       return "sparkles"
        case .vocalForward: return "person.wave.2"
        case .trebleTame:   return "ear.trianglebadge.exclamationmark"
        }
    }

    var tagline: String {
        switch self {
        case .flat:
            return "Reset Bass, Mids, and Treble to 0."
        case .loudness:
            return "Lifts bass and treble — restores the perceived balance at low listening volume (Fletcher-Munson)."
        case .warm:
            return "Adds bass, gently rolls off treble — easier on long sessions."
        case .bright:
            return "Treble emphasis with a touch less bass — adds air."
        case .vocalForward:
            return "Mids boost, slight bass + treble cut — pushes voices forward."
        case .trebleTame:
            return "Treble cut — helpful for hyperacusis or harsh program material."
        }
    }

    func gain(forHz hz: Double) -> Double { gains[hz] ?? 0 }

    /// Keyed by band centre frequency: 250 Hz Bass shelf, 1 kHz Mids
    /// parametric, 5 kHz Treble shelf — matches `SimpleEQView.simpleBands`.
    var gains: [Double: Double] {
        switch self {
        case .flat:
            return [:]
        case .loudness:
            return [250: 4, 1000: 0, 5000: 3]
        case .warm:
            return [250: 3, 1000: 0, 5000: -2]
        case .bright:
            return [250: -1, 1000: 0, 5000: 3]
        case .vocalForward:
            return [250: -2, 1000: 3, 5000: -1]
        case .trebleTame:
            return [250: 0, 1000: 0, 5000: -4]
        }
    }
}
