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
    /// Captured pitch matches for the guided flow. Tinnitus pitch matching is
    /// imprecise and octave-confusable, so a repeatable average/range is more
    /// honest than a single "definitive" number.
    @State private var matches: [Double] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                introCard
                frequencyReadout
                sweepSurface
                fineTuneControls
                guidedMatchingSection
                volumeRow
                actionsRow
                notchSection
                TinnitusCheckInView(store: audioState.tinnitusCheckIns)
                disclaimer
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Tinnitus Notch")
        .onDisappear { generator.stop() }
    }

    /// Notch filter controls — frequency / depth / width — bound to
    /// the active profile. When `separateNotch` is on, two panels
    /// stack so the user can dial in independent L / R notches (e.g.
    /// unilateral tinnitus). When off, one panel writes both ears in
    /// lockstep — every edit on the visible Left binding mirrors to
    /// Right so the audio chain sees identical values. Hidden when
    /// no profile is loaded.
    @ViewBuilder private var notchSection: some View {
        if let profile = audioState.activeProfile(in: profileStore) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Notch filter", systemImage: "bandage")
                        .font(.title3.weight(.semibold))
                    Spacer()
                }
                // Notch-vs-correction conflict (spec §6): warn when this
                // notch cuts where the audiogram correction boosts.
                CorrectionConflictChip(crossLink: .audiogram)
                // Honest preview of the band being reduced — the same
                // parametric dip the audio applies, both ears when separate.
                NotchPreviewView(
                    leftNotch: profile.leftNotch,
                    rightNotch: profile.rightNotch,
                    separate: profile.separateNotch,
                    leftColor: audioState.preferences.leftEarColor,
                    rightColor: audioState.preferences.rightEarColor
                )
                separateToggleRow(profile)
                if profile.separateNotch {
                    NotchControlView(
                        notch: leftNotchBinding(for: profile),
                        title: "Left ear",
                        symbol: "ear"
                    )
                    NotchControlView(
                        notch: rightNotchBinding(for: profile),
                        title: "Right ear",
                        symbol: "ear"
                    )
                } else {
                    // Linked: edits flow to both notches in one
                    // write so the engine never sees an asymmetric
                    // intermediate state during a slider drag.
                    NotchControlView(notch: linkedNotchBinding(for: profile))
                }
            }
        }
    }

    @ViewBuilder private func separateToggleRow(_ profile: HearingProfile) -> some View {
        HStack {
            Toggle("Separate L + R notch", isOn: Binding(
                get: { profile.separateNotch },
                set: { newValue in
                    var updated = profile
                    updated.separateNotch = newValue
                    // Snap the right notch to the left when turning
                    // separate off, so the linked-mode panel reflects
                    // the value the user has been working with.
                    if !newValue {
                        updated.rightNotch = updated.leftNotch
                    }
                    try? profileStore.save(updated)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            Spacer()
            Text("Useful for unilateral tinnitus or asymmetric pitch.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Linked binding — every write goes to both ears so the engine
    /// applies identical notches L and R.
    private func linkedNotchBinding(for profile: HearingProfile) -> Binding<TinnitusNotch> {
        Binding(
            get: { profile.leftNotch },
            set: { newValue in
                var updated = profile
                updated.leftNotch = newValue
                updated.rightNotch = newValue
                try? profileStore.save(updated)
            }
        )
    }

    private func leftNotchBinding(for profile: HearingProfile) -> Binding<TinnitusNotch> {
        Binding(
            get: { profile.leftNotch },
            set: { newValue in
                var updated = profile
                updated.leftNotch = newValue
                try? profileStore.save(updated)
            }
        )
    }

    private func rightNotchBinding(for profile: HearingProfile) -> Binding<TinnitusNotch> {
        Binding(
            get: { profile.rightNotch },
            set: { newValue in
                var updated = profile
                updated.rightNotch = newValue
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
            Spacer()
            HelpContextButton(.tinnitusToneMatching, label: "tinnitus tone matching")
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
                        .font(.caption.monospaced())
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
            // Tone Finder's whole purpose is "what frequency matches
            // my tinnitus" — without an adjustable accessibility
            // surface, VO users and no-mouse users couldn't operate
            // the screen at all. .accessibilityAdjustableAction wires
            // arrow keys / VO swipes to ±10 Hz coarse nudges (matches
            // the fine-tune buttons below); the +/− 1 / 100 buttons
            // remain as standard controls for finer / coarser steps.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tone frequency")
            .accessibilityValue("\(Int(currentHz.rounded())) hertz")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: nudge(10)
                case .decrement: nudge(-10)
                @unknown default: break
                }
            }
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
                .foregroundStyle(.secondary)
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

            setAsNotchButton

            Spacer()

            if let confirmed = lastConfirmedFrequency {
                Label("Notch updated to \(Int(confirmed)) Hz", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        }
    }

    private var disclaimer: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Best-for / not-best-for: a notch suits steady tonal ringing and
            // does little for non-tonal sounds. Framed as suitability, not a
            // diagnosis.
            VStack(alignment: .leading, spacing: 8) {
                Label("When a notch may help", systemImage: "checkmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                bestForRow(
                    symbol: "checkmark",
                    tint: .green,
                    lead: "Best for",
                    text: "steady, tone-like ringing at a pitch you can find again."
                )
                bestForRow(
                    symbol: "minus",
                    tint: .secondary,
                    lead: "Less suited",
                    text: "hissing, roaring, clicking, pulsing, or tinnitus that changes pitch often."
                )
            }

            Divider()

            // Distinct medical-referral callout — deliberately stronger styling
            // than the suitability rows so red-flag symptoms don't read as just
            // more audio guidance.
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "stethoscope")
                    .foregroundStyle(.orange)
                    .font(.title3)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text("See a hearing professional")
                        .font(.subheadline.weight(.semibold))
                    Text("Pulsatile (heartbeat-like) tinnitus, a sudden change in one ear, new hearing loss, dizziness, or pain deserve medical evaluation — not more audio tweaking.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.orange.opacity(0.10))
            )

            // Non-clinical framing.
            VStack(alignment: .leading, spacing: 6) {
                Label("Non-clinical", systemImage: "info.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("SherlockEQ doesn't diagnose, measure, or treat tinnitus. The notch simply reduces audio energy around the pitch you selected — a way to explore whether listening feels less fatiguing. Evidence for notched-sound approaches is mixed, and hearing-aid evaluation or CBT have stronger support for persistent, bothersome tinnitus.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    @ViewBuilder
    private func bestForRow(symbol: String, tint: Color, lead: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 16)
            (Text(lead + ": ").font(.callout.weight(.semibold))
                + Text(text).font(.callout))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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

    private var freqAxis: LogFreqAxis { LogFreqAxis(minHz: minHz, maxHz: maxHz) }

    private func xFor(hz: Double, width: CGFloat) -> CGFloat {
        freqAxis.x(forHz: hz, width: width)
    }

    private func hzFor(x: CGFloat, width: CGFloat) -> Double {
        freqAxis.hz(forX: x, width: width)
    }

    private func nudge(_ delta: Int) {
        let target = generator.targetFrequencyHz + Double(delta)
        generator.targetFrequencyHz = max(minHz, min(maxHz, target))
    }

    /// Action button next to Play. Single bordered button in the
    /// linked-notch case, three-way Menu (Left / Right / Both) when
    /// the user has turned on per-ear notch. The menu form keeps the
    /// same affordance (still a bandage-labelled control) but lets
    /// the user pick a target without leaving the tone-finder flow.
    @ViewBuilder private var setAsNotchButton: some View {
        let profile = audioState.activeProfile(in: profileStore)
        if profile?.separateNotch == true {
            Menu {
                Button("Set as Left ear notch")  { setAsNotch(.left) }
                Button("Set as Right ear notch") { setAsNotch(.right) }
                Divider()
                Button("Set as Both notches")    { setAsNotch(.both) }
            } label: {
                Label("Set as Notch Frequency", systemImage: "bandage")
            }
            .menuStyle(.borderedButton)
            .controlSize(.large)
            .disabled(profile == nil)
        } else {
            Button {
                setAsNotch(.both)
            } label: {
                Label("Set as Notch Frequency", systemImage: "bandage")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(profile == nil)
        }
    }

    private enum NotchTarget { case left, right, both }

    private func setAsNotch(_ target: NotchTarget) {
        applyNotch(frequency: currentHz, target: target)
    }

    /// Commit a notch frequency for the target ear(s), enabling the notch.
    /// Shared by the "Set as Notch" button (current tone) and the guided
    /// flow (matched-average tone).
    private func applyNotch(frequency: Double, target: NotchTarget) {
        guard var profile = audioState.activeProfile(in: profileStore) else { return }
        switch target {
        case .left:
            profile.leftNotch.frequencyHz = frequency
            profile.leftNotch.enabled = true
        case .right:
            profile.rightNotch.frequencyHz = frequency
            profile.rightNotch.enabled = true
        case .both:
            profile.leftNotch.frequencyHz = frequency
            profile.leftNotch.enabled = true
            profile.rightNotch.frequencyHz = frequency
            profile.rightNotch.enabled = true
        }
        try? profileStore.save(profile)
        lastConfirmedFrequency = frequency
    }

    // MARK: - Guided matching

    /// Optional, collapsed-by-default protocol that treats pitch matching as
    /// the imprecise, octave-confusable task it is: sweep, compare octaves,
    /// capture a few matches, then use their average/range rather than one
    /// "definitive" number.
    @ViewBuilder private var guidedMatchingSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 16) {
                matchProtocolSteps
                octaveCheckRow
                matchCaptureRow
            }
            .padding(.top, 10)
        } label: {
            Label("Guided matching (optional)", systemImage: "list.number")
                .font(.subheadline.weight(.medium))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    private var matchProtocolSteps: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.protocolSteps.enumerated()), id: \.offset) { idx, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(idx + 1)")
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(.tint)
                        .frame(width: 16, alignment: .trailing)
                    Text(step)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static let protocolSteps: [String] = [
        "Start a bit below where your ringing sits.",
        "Sweep slowly upward and stop when the tone feels closest.",
        "Compare a few nearby tones — small moves change the match.",
        "Check for octave confusion (below), a common trap.",
        "Match the pitch first; adjust loudness separately.",
        "Capture the match a few times — save only what you can repeat."
    ]

    /// Octave-confusion check: jump the tone down/up an octave so the user can
    /// tell whether the match is really at f, or an octave off (very common).
    private var octaveCheckRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Octave check")
                .font(.callout.weight(.semibold))
            Text("A tone one octave away can sound deceptively similar. Compare, then return.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { jumpOctave(-1) } label: { Label("Down 1 octave", systemImage: "arrow.down") }
                Button { jumpOctave(+1) } label: { Label("Up 1 octave", systemImage: "arrow.up") }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var matchCaptureRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your matches")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button { recordMatch() } label: {
                    Label("Capture match \(matches.count + 1)", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                if !matches.isEmpty {
                    Button(role: .destructive) { matches.removeAll() } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if matches.isEmpty {
                Text("No matches yet. Capture the same pitch a few times to see a suggested average and range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                matchChips
                matchSummary
            }
        }
    }

    private var matchChips: some View {
        HStack(spacing: 6) {
            ForEach(Array(matches.enumerated()), id: \.offset) { idx, hz in
                Text("#\(idx + 1)  \(Int(hz)) Hz")
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.12))
                    )
            }
            Spacer()
        }
    }

    @ViewBuilder private var matchSummary: some View {
        let avg = matches.reduce(0, +) / Double(matches.count)
        let lo = matches.min() ?? avg
        let hi = matches.max() ?? avg
        VStack(alignment: .leading, spacing: 8) {
            if matches.count < 2 {
                Text("Suggested: \(Int(avg)) Hz — capture 1–2 more to gauge how repeatable it is.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                (Text("Suggested: ").font(.callout)
                    + Text("\(Int(avg.rounded())) Hz").font(.callout.weight(.semibold))
                    + Text("  (range \(Int(lo))–\(Int(hi)) Hz)").font(.callout))
                    .foregroundStyle(.secondary)
            }
            Button {
                let target = Int(avg.rounded())
                generator.targetFrequencyHz = Double(target)
                applyNotch(frequency: Double(target), target: .both)
            } label: {
                Label("Use average as notch (both ears)", systemImage: "bandage")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func recordMatch() {
        // Cap at a small, sane number — more than a handful adds noise, not
        // signal, for a subjective match.
        guard matches.count < 6 else { return }
        matches.append(currentHz.rounded())
    }

    private func jumpOctave(_ direction: Int) {
        let factor = direction >= 0 ? 2.0 : 0.5
        let target = generator.targetFrequencyHz * factor
        generator.targetFrequencyHz = max(minHz, min(maxHz, target))
    }
}
