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
        let icon: String
    }

    private static let simpleBands: [SimpleBand] = [
        SimpleBand(label: "Bass",   frequencyHz: 100,  bandwidth: 1.8, icon: "speaker.wave.2.fill"),
        SimpleBand(label: "Mids",   frequencyHz: 1000, bandwidth: 1.8, icon: "waveform"),
        SimpleBand(label: "Treble", frequencyHz: 5000, bandwidth: 1.5, icon: "music.note"),
    ]

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
                Text("Three quick knobs per ear. For finer control switch to Advanced or Expert.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                previewCanvas(profile)
                HStack(alignment: .top, spacing: 16) {
                    bandColumn(for: profile, ear: .left, color: .blue)
                    bandColumn(for: profile, ear: .right, color: .red)
                }
                resetButton(profile)
                educationCard
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @State private var dummySelection: UUID? = nil

    @ViewBuilder
    private func previewCanvas(_ profile: HearingProfile) -> some View {
        ParametricCanvasView(
            bands: .constant(profile.leftEar.bands),
            shadowBands: profile.rightEar.bands,
            notch: profile.notch,
            spectrumBinsDB: audioState.spectrum.logSpectrumDB,
            spectrumPeakHoldDB: audioState.spectrum.logSpectrumPeakHoldDB,
            spectrumSampleRate: audioState.audio.outputSampleRate ?? 48_000,
            earColor: .blue,
            shadowColor: .red,
            readOnly: true,
            selectedBandID: $dummySelection
        )
        .frame(height: 180)
    }

    private enum Ear { case left, right }

    @ViewBuilder
    private func bandColumn(for profile: HearingProfile, ear: Ear, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(ear == .left ? "Left ear" : "Right ear")
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
            Text("The three sliders adjust a single wide parametric band at 100 Hz / 1 kHz / 5 kHz. Moving a slider to 0 removes that band — moving it back creates it again. Switching to Advanced or Expert shows the same bands alongside any others you've added.")
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
        return EQBandLookup.gain(at: band.frequencyHz, in: bands)
    }

    private func setGain(_ gain: Double, profile: HearingProfile, ear: Ear, band: SimpleBand) {
        var updated = profile
        var bands = ear == .left ? updated.leftEar.bands : updated.rightEar.bands
        EQBandLookup.setGain(gain, at: band.frequencyHz, bandwidth: band.bandwidth, in: &bands)
        if ear == .left { updated.leftEar.bands = bands } else { updated.rightEar.bands = bands }
        try? profileStore.save(updated)
    }

    private func reset(_ profile: HearingProfile) {
        var updated = profile
        for band in Self.simpleBands {
            var leftBands = updated.leftEar.bands
            EQBandLookup.setGain(0, at: band.frequencyHz, bandwidth: band.bandwidth, in: &leftBands)
            updated.leftEar.bands = leftBands

            var rightBands = updated.rightEar.bands
            EQBandLookup.setGain(0, at: band.frequencyHz, bandwidth: band.bandwidth, in: &rightBands)
            updated.rightEar.bands = rightBands
        }
        try? profileStore.save(updated)
    }

    private func formatGain(_ db: Double) -> String {
        if abs(db) < 0.05 { return "0 dB" }
        return String(format: "%+.1f dB", db)
    }
}
