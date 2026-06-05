import SwiftUI

/// Tinnitus Notch screen — sweep a pure sine to identify the pitch
/// closest to your ringing (Tone Finder), then dial in the notch
/// filter that de-emphasises it on the active profile.
/// (spec §5.3 + §5.10: large freq display, log-scale sweep, fine-tune
/// stepper, on/off + frequency + depth + width controls, non-clinical
/// copy. Tone Finder used to live on its own screen and the notch
/// settings under Expert EQ; consolidated here so they read as one
/// task — identify, then dial in.)
struct ToneFinderView: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore

    private let minHz: Double = 1000
    private let maxHz: Double = 16_000

    @State private var lastConfirmedFrequency: Double?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                introCard
                frequencyReadout
                sweepSurface
                fineTuneControls
                volumeRow
                actionsRow
                notchSection
                disclaimer
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Tinnitus Notch")
        .onDisappear { generator.stop() }
    }

    /// Notch filter controls — frequency / depth / width — bound to the
    /// active profile. Hidden when no profile is loaded (matches the
    /// "Set as Notch" button's disabled state, so the screen stays
    /// coherent at first launch before profile seeding).
    @ViewBuilder private var notchSection: some View {
        if let profile = audioState.activeProfile(in: profileStore) {
            NotchControlView(notch: notchBinding(for: profile))
        }
    }

    private func notchBinding(for profile: HearingProfile) -> Binding<TinnitusNotch> {
        Binding(
            get: { profile.notch },
            set: { newValue in
                var updated = profile
                updated.notch = newValue
                try? profileStore.save(updated)
            }
        )
    }

    private var generator: SineToneGenerator { audioState.audio.toneGenerator }

    private var currentHz: Double { generator.targetFrequencyHz }

    // MARK: - Cards

    private var introCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "tuningfork")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("Find the pitch closest to your ringing")
                    .font(.title3.weight(.semibold))
                Text("Tap Play, then drag the bar below to sweep the sine through your hearing range. When the tone sits at the same pitch as your tinnitus, hit \u{201C}Set as Notch.\u{201D}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var frequencyReadout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(formattedFrequency)
                    .font(.system(size: 60, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("Hz")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(noteApproximation.label)
                    .font(.title2.monospaced().weight(.semibold))
                Text(noteApproximation.detail)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sweepSurface: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.secondary.opacity(0.08))
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.secondary.opacity(0.2))

                ForEach(majorTicks, id: \.self) { hz in
                    let x = xFor(hz: hz, width: geo.size.width)
                    Path { path in
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    }
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)

                    Text(formatTick(hz))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .position(x: x, y: geo.size.height - 12)
                }

                let cursorX = xFor(hz: currentHz, width: geo.size.width)
                Path { path in
                    path.move(to: CGPoint(x: cursorX, y: 0))
                    path.addLine(to: CGPoint(x: cursorX, y: geo.size.height))
                }
                .stroke(Color.accentColor, lineWidth: 2)

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 18, height: 18)
                    .position(x: cursorX, y: geo.size.height / 2)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        generator.targetFrequencyHz = hzFor(x: value.location.x, width: geo.size.width)
                    }
            )
        }
        .frame(height: 120)
    }

    private var fineTuneControls: some View {
        HStack(spacing: 8) {
            Text("Fine tune")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button { nudge(-100) } label: { Text("−100") }
            Button { nudge(-10) }  label: { Text("−10")  }
            Button { nudge(-1) }   label: { Text("−1")   }

            Text("Hz")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)

            Button { nudge(+1) }   label: { Text("+1")   }
            Button { nudge(+10) }  label: { Text("+10")  }
            Button { nudge(+100) } label: { Text("+100") }

            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var volumeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.1")
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { Double(generator.amplitude) },
                    set: { generator.amplitude = Float($0) }
                ),
                in: 0.005...0.2
            )
            Image(systemName: "speaker.wave.3")
                .foregroundStyle(.secondary)
            Text(amplitudeLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
    }

    private var actionsRow: some View {
        HStack(spacing: 12) {
            Button {
                generator.toggle()
            } label: {
                Label(
                    generator.isPlaying ? "Stop" : "Play",
                    systemImage: generator.isPlaying ? "stop.fill" : "play.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])

            Button {
                setAsNotch()
            } label: {
                Label("Set as Notch Frequency", systemImage: "bandage")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(audioState.activeProfile(in: profileStore) == nil)

            Spacer()

            if let confirmed = lastConfirmedFrequency {
                Label("Notch updated to \(Int(confirmed)) Hz", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        }
    }

    private var disclaimer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Non-clinical", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("AuditumEQ doesn't diagnose, measure, or treat tinnitus. This tool helps you pick a single frequency for the optional notch filter — a way to subtly de-emphasize the pitch that's mentally fatiguing. If your tinnitus changes or worsens, see a hearing professional.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    // MARK: - Helpers

    private var formattedFrequency: String {
        Int(currentHz.rounded()).formatted()
    }

    private var amplitudeLabel: String {
        // Convert linear amplitude → approximate dBFS RMS for a sine
        // (RMS = amp / sqrt(2))
        let amp = Double(generator.amplitude)
        let rms = amp / 2.squareRoot()
        let dbfs = 20 * log10(max(rms, 1e-6))
        return String(format: "%.0f dBFS", dbfs)
    }

    private struct NoteApprox {
        let label: String
        let detail: String
    }

    private var noteApproximation: NoteApprox {
        // A4 = 440 Hz. semitones from A4 = 12 * log2(f / 440)
        let semis = 12 * log2(currentHz / 440)
        let nearest = Int(semis.rounded())
        let cents = (semis - Double(nearest)) * 100
        let noteNames = ["A", "A#", "B", "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#"]
        // nearest = 0 → A4; positive moves up.
        let nameIdx = ((nearest % 12) + 12) % 12
        // Octaves: A4 is octave 4. A5 (nearest=12) is octave 5. Note that
        // C4 is 3 semitones above A3 → handle wrap.
        let absSemis = nearest + 9               // shift so 0 = C0
        let octave = absSemis >= 0 ? absSemis / 12 : (absSemis - 11) / 12
        let centsString = String(format: "%+d¢", Int(cents.rounded()))
        return NoteApprox(
            label: "\(noteNames[nameIdx])\(octave)",
            detail: centsString
        )
    }

    private var majorTicks: [Double] {
        [1000, 2000, 4000, 8000, 16000]
    }

    private func formatTick(_ hz: Double) -> String {
        let k = hz / 1000
        return "\(Int(k))k"
    }

    private func xFor(hz: Double, width: CGFloat) -> CGFloat {
        let clamped = max(minHz, min(maxHz, hz))
        let logMin = log10(minHz)
        let logMax = log10(maxHz)
        return CGFloat((log10(clamped) - logMin) / (logMax - logMin)) * width
    }

    private func hzFor(x: CGFloat, width: CGFloat) -> Double {
        let frac = max(0, min(1, Double(x / width)))
        let logMin = log10(minHz)
        let logMax = log10(maxHz)
        return pow(10, logMin + frac * (logMax - logMin))
    }

    private func nudge(_ delta: Int) {
        let target = generator.targetFrequencyHz + Double(delta)
        generator.targetFrequencyHz = max(minHz, min(maxHz, target))
    }

    private func setAsNotch() {
        guard var profile = audioState.activeProfile(in: profileStore) else { return }
        profile.notch.frequencyHz = currentHz
        profile.notch.enabled = true
        try? profileStore.save(profile)
        lastConfirmedFrequency = currentHz
    }
}
