import SwiftUI

/// 10-band graphic EQ — vertical sliders at standard octave-spaced centers.
/// Like Simple, it shares the underlying band array with the other tabs.
struct AdvancedEQView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var audioState: AudioState

    private static let frequencies: [Double] = [
        31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]
    private static let bandwidth: Double = 1.0   // 1 octave Q

    /// Reads the active profile's `separateChannels` flag. Toggle
    /// lives on Profile Detail. Default for new profiles is false
    /// (linked).
    private var linkChannels: Bool {
        !(audioState.activeProfile(in: profileStore)?.separateChannels ?? false)
    }

    var body: some View {
        if let profile = audioState.activeProfile(in: profileStore) {
            content(profile)
        } else {
            ContentUnavailableView(
                "No active profile",
                systemImage: "slider.vertical.3",
                description: Text("Make a profile active to use the Advanced EQ.")
            )
        }
    }

    @ViewBuilder private func content(_ profile: HearingProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                topBar
                previewCanvas(profile)
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
    /// consistent across tabs. Each preset overwrites the 10 Advanced
    /// bands on both ears; other tabs' bands stay untouched.
    private var presetMenu: some View {
        Menu {
            ForEach(AdvancedEQPreset.allCases) { preset in
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
        .help("One-click curated curves for the 10 Advanced bands.")
        .accessibilityLabel("Advanced EQ preset")
    }

    private func apply(_ preset: AdvancedEQPreset) {
        guard let profile = audioState.activeProfile(in: profileStore) else { return }
        var updated = profile
        var lb = updated.leftEar.bands
        var rb = updated.rightEar.bands
        for freq in Self.frequencies {
            let gain = preset.gain(forHz: freq)
            EQBandLookup.setGain(gain, at: freq, bandwidth: Self.bandwidth, filterType: .parametric, in: &lb)
            EQBandLookup.setGain(gain, at: freq, bandwidth: Self.bandwidth, filterType: .parametric, in: &rb)
        }
        updated.leftEar.bands = lb
        updated.rightEar.bands = rb
        try? profileStore.save(updated)
    }

    @State private var dummySelection: UUID? = nil

    @ViewBuilder
    private func previewCanvas(_ profile: HearingProfile) -> some View {
        LiveParametricCanvas(
            spectrum: audioState.spectrum,
            preSpectrum: nil,
            bands: .constant(profile.leftEar.bands),
            shadowBands: profile.rightEar.bands,
            notch: profile.notch,
            spectrumSampleRate: audioState.audio.outputSampleRate ?? 48_000,
            earColor: audioState.leftEarColor,
            shadowColor: audioState.rightEarColor,
            readOnly: true,
            selectedBandID: $dummySelection
        )
        .frame(height: 180)
    }

    @ViewBuilder
    private func slidersRow(_ profile: HearingProfile) -> some View {
        HStack(alignment: .top, spacing: 6) {
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
        VStack(spacing: 8) {
            Text(formatFreq(frequency))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                if linkChannels {
                    VerticalGainSlider(
                        value: gainBinding(profile: profile, frequency: frequency, channel: .left),
                        range: -12...12,
                        tint: audioState.leftEarColor
                    )
                    .frame(width: 40)
                } else {
                    VerticalGainSlider(
                        value: gainBinding(profile: profile, frequency: frequency, channel: .left),
                        range: -12...12,
                        tint: audioState.leftEarColor
                    )
                    .frame(width: 26)
                    VerticalGainSlider(
                        value: gainBinding(profile: profile, frequency: frequency, channel: .right),
                        range: -12...12,
                        tint: audioState.rightEarColor
                    )
                    .frame(width: 26)
                }
            }
            .frame(width: Self.columnWidth, height: 220)

            Text(formatGain(displayedGain(profile: profile, frequency: frequency)))
                .font(.caption.monospaced().weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private enum Channel { case left, right }

    private func resetButton(_ profile: HearingProfile) -> some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                reset(profile)
            } label: {
                Label("Flatten Advanced bands", systemImage: "arrow.counterclockwise")
            }
        }
    }

    // MARK: - Binding helpers

    private func displayedGain(profile: HearingProfile, frequency: Double) -> Double {
        let left = EQBandLookup.gain(at: frequency, filterType: .parametric, in: profile.leftEar.bands)
        if linkChannels { return left }
        let right = EQBandLookup.gain(at: frequency, filterType: .parametric, in: profile.rightEar.bands)
        return (left + right) / 2
    }

    private func gainBinding(profile: HearingProfile, frequency: Double, channel: Channel) -> Binding<Double> {
        Binding(
            get: { gain(profile: profile, frequency: frequency, channel: channel) },
            set: { newValue in setGain(newValue, profile: profile, frequency: frequency, channel: channel) }
        )
    }

    private func gain(profile: HearingProfile, frequency: Double, channel: Channel) -> Double {
        switch channel {
        case .left:  return EQBandLookup.gain(at: frequency, filterType: .parametric, in: profile.leftEar.bands)
        case .right: return EQBandLookup.gain(at: frequency, filterType: .parametric, in: profile.rightEar.bands)
        }
    }

    private func setGain(_ gain: Double, profile: HearingProfile, frequency: Double, channel: Channel) {
        var updated = profile
        if linkChannels {
            var lb = updated.leftEar.bands
            EQBandLookup.setGain(gain, at: frequency, bandwidth: Self.bandwidth, filterType: .parametric, in: &lb)
            updated.leftEar.bands = lb
            var rb = updated.rightEar.bands
            EQBandLookup.setGain(gain, at: frequency, bandwidth: Self.bandwidth, filterType: .parametric, in: &rb)
            updated.rightEar.bands = rb
        } else {
            switch channel {
            case .left:
                var lb = updated.leftEar.bands
                EQBandLookup.setGain(gain, at: frequency, bandwidth: Self.bandwidth, filterType: .parametric, in: &lb)
                updated.leftEar.bands = lb
            case .right:
                var rb = updated.rightEar.bands
                EQBandLookup.setGain(gain, at: frequency, bandwidth: Self.bandwidth, filterType: .parametric, in: &rb)
                updated.rightEar.bands = rb
            }
        }
        try? profileStore.save(updated)
    }

    private func reset(_ profile: HearingProfile) {
        var updated = profile
        for freq in Self.frequencies {
            var lb = updated.leftEar.bands
            EQBandLookup.setGain(0, at: freq, bandwidth: Self.bandwidth, filterType: .parametric, in: &lb)
            updated.leftEar.bands = lb
            var rb = updated.rightEar.bands
            EQBandLookup.setGain(0, at: freq, bandwidth: Self.bandwidth, filterType: .parametric, in: &rb)
            updated.rightEar.bands = rb
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

    private func formatGain(_ db: Double) -> String {
        if abs(db) < 0.05 { return "0" }
        return String(format: "%+.1f", db)
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

    var body: some View {
        GeometryReader { geo in
            let zeroY = yFor(0, height: geo.size.height)
            let valueY = yFor(clampedValue, height: geo.size.height)

            ZStack {
                // Track
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 8)

                // Fill between value and zero
                Capsule()
                    .fill(tint.opacity(0.55))
                    .frame(width: 8, height: abs(valueY - zeroY))
                    .position(
                        x: geo.size.width / 2,
                        y: (valueY + zeroY) / 2
                    )

                // 0 dB tick
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
                        newValue = (newValue * 2).rounded() / 2   // 0.5 dB steps
                        value = max(range.lowerBound, min(range.upperBound, newValue))
                    }
            )
        }
    }

    private var clampedValue: Double {
        max(range.lowerBound, min(range.upperBound, value))
    }

    private func yFor(_ db: Double, height: CGFloat) -> CGFloat {
        let normalized = (range.upperBound - db) / (range.upperBound - range.lowerBound)
        return CGFloat(normalized) * height
    }
}

// MARK: - Advanced presets

/// Curated starting points for the 10-band Advanced EQ. Each preset
/// lists per-band dB offsets keyed by the band's centre frequency
/// (Hz). Bands not in `gains` get 0 (flat / removed from the chain).
enum AdvancedEQPreset: String, CaseIterable, Identifiable {
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

    /// Keyed by band centre frequency — matches `AdvancedEQView.frequencies`.
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
