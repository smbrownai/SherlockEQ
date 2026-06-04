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
    }

    /// Bass + Treble are shelves so adjusting them never stacks weirdly
    /// with Advanced or Expert's parametric peaks at the same frequencies
    /// — a shelf is a fundamentally different filter shape. Mids stays a
    /// parametric peak (no equivalent shelf for the middle region).
    private static let simpleBands: [SimpleBand] = [
        SimpleBand(label: "Bass",   frequencyHz: 250,  bandwidth: 0.707, filterType: .lowShelf,  icon: "speaker.wave.2.fill"),
        SimpleBand(label: "Mids",   frequencyHz: 1000, bandwidth: 1.8,   filterType: .parametric, icon: "waveform"),
        SimpleBand(label: "Treble", frequencyHz: 5000, bandwidth: 0.707, filterType: .highShelf, icon: "music.note"),
    ]

    @State private var linkChannels: Bool = true

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
                previewCanvas(profile)
                if linkChannels {
                    bandColumn(for: profile, ear: .left, color: .accentColor, title: "Both ears")
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        bandColumn(for: profile, ear: .left, color: audioState.leftEarColor, title: "Left ear")
                        bandColumn(for: profile, ear: .right, color: audioState.rightEarColor, title: "Right ear")
                    }
                }
                resetButton(profile)
                educationCard
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Text("Three quick knobs per ear")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("Link L + R", isOn: $linkChannels)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
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

    private enum Ear { case left, right }

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
            HStack {
                Text("-12 dB").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("0").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("+12 dB").font(.caption2).foregroundStyle(.tertiary)
            }
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

    private var educationCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("How Simple works", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
            Text("Bass and Treble are *shelf* filters — Bass lifts or cuts everything below ~250 Hz, Treble does the same above ~5 kHz. Mids is a wide peak at 1 kHz. Shelves don't stack badly with Advanced/Expert's per-band peaks, so you can roughly shape your sound here and then refine in the other tabs without doubling up.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.05))
        )
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
        if linkChannels {
            var lb = updated.leftEar.bands
            EQBandLookup.setGain(gain, at: band.frequencyHz, bandwidth: band.bandwidth, filterType: band.filterType, in: &lb)
            updated.leftEar.bands = lb
            var rb = updated.rightEar.bands
            EQBandLookup.setGain(gain, at: band.frequencyHz, bandwidth: band.bandwidth, filterType: band.filterType, in: &rb)
            updated.rightEar.bands = rb
        } else {
            var bands = ear == .left ? updated.leftEar.bands : updated.rightEar.bands
            EQBandLookup.setGain(gain, at: band.frequencyHz, bandwidth: band.bandwidth, filterType: band.filterType, in: &bands)
            if ear == .left { updated.leftEar.bands = bands } else { updated.rightEar.bands = bands }
        }
        try? profileStore.save(updated)
    }

    private func reset(_ profile: HearingProfile) {
        var updated = profile
        for band in Self.simpleBands {
            var leftBands = updated.leftEar.bands
            EQBandLookup.setGain(0, at: band.frequencyHz, bandwidth: band.bandwidth, filterType: band.filterType, in: &leftBands)
            updated.leftEar.bands = leftBands

            var rightBands = updated.rightEar.bands
            EQBandLookup.setGain(0, at: band.frequencyHz, bandwidth: band.bandwidth, filterType: band.filterType, in: &rightBands)
            updated.rightEar.bands = rightBands
        }
        try? profileStore.save(updated)
    }

    private func formatGain(_ db: Double) -> String {
        if abs(db) < 0.05 { return "0 dB" }
        return String(format: "%+.1f dB", db)
    }
}
