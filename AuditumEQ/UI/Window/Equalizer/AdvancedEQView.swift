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

    @State private var linkChannels: Bool = true

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
            VStack(alignment: .leading, spacing: 20) {
                header
                previewCanvas(profile)
                Toggle("Link left + right channels", isOn: $linkChannels)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                slidersRow(profile)
                resetButton(profile)
            }
            .padding(24)
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
            spectrumBinsDB: audioState.spectrum.spectrumBinsDB,
            spectrumPeakHoldDB: audioState.spectrum.spectrumPeakHoldDB,
            spectrumSampleRate: audioState.audio.outputSampleRate ?? 48_000,
            earColor: .blue,
            shadowColor: .red,
            readOnly: true,
            selectedBandID: $dummySelection
        )
        .frame(height: 180)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Advanced EQ")
                .font(.title2.weight(.semibold))
            Text("10 octave-spaced bands per ear. Sliders edit one wide parametric band each.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
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

    @ViewBuilder
    private func bandColumn(profile: HearingProfile, frequency: Double) -> some View {
        VStack(spacing: 8) {
            Text(formatFreq(frequency))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                VerticalGainSlider(
                    value: gainBinding(profile: profile, frequency: frequency, channel: .left),
                    range: -12...12,
                    tint: .blue
                )
                .frame(width: linkChannels ? 40 : 28)
                if !linkChannels {
                    VerticalGainSlider(
                        value: gainBinding(profile: profile, frequency: frequency, channel: .right),
                        range: -12...12,
                        tint: .red
                    )
                    .frame(width: 28)
                }
            }
            .frame(height: 220)

            Text(formatGain(displayedGain(profile: profile, frequency: frequency)))
                .font(.caption.monospaced().weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: 56)
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
        let left = EQBandLookup.gain(at: frequency, in: profile.leftEar.bands)
        if linkChannels { return left }
        let right = EQBandLookup.gain(at: frequency, in: profile.rightEar.bands)
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
        case .left:  return EQBandLookup.gain(at: frequency, in: profile.leftEar.bands)
        case .right: return EQBandLookup.gain(at: frequency, in: profile.rightEar.bands)
        }
    }

    private func setGain(_ gain: Double, profile: HearingProfile, frequency: Double, channel: Channel) {
        var updated = profile
        if linkChannels {
            var lb = updated.leftEar.bands
            EQBandLookup.setGain(gain, at: frequency, bandwidth: Self.bandwidth, in: &lb)
            updated.leftEar.bands = lb
            var rb = updated.rightEar.bands
            EQBandLookup.setGain(gain, at: frequency, bandwidth: Self.bandwidth, in: &rb)
            updated.rightEar.bands = rb
        } else {
            switch channel {
            case .left:
                var lb = updated.leftEar.bands
                EQBandLookup.setGain(gain, at: frequency, bandwidth: Self.bandwidth, in: &lb)
                updated.leftEar.bands = lb
            case .right:
                var rb = updated.rightEar.bands
                EQBandLookup.setGain(gain, at: frequency, bandwidth: Self.bandwidth, in: &rb)
                updated.rightEar.bands = rb
            }
        }
        try? profileStore.save(updated)
    }

    private func reset(_ profile: HearingProfile) {
        var updated = profile
        for freq in Self.frequencies {
            var lb = updated.leftEar.bands
            EQBandLookup.setGain(0, at: freq, bandwidth: Self.bandwidth, in: &lb)
            updated.leftEar.bands = lb
            var rb = updated.rightEar.bands
            EQBandLookup.setGain(0, at: freq, bandwidth: Self.bandwidth, in: &rb)
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
