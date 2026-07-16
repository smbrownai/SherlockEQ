import SwiftUI

/// Tinnitus Notch screen. Three separable jobs, now visually separated:
///   1. **Pitch matching** — a short guided flow (level → sweep → compare →
///      use) to find the tone closest to your ringing.
///   2. **Notch configuration** — the filter that de-emphasises that pitch.
///      Collapsed to a preview + enable when off; full controls when on.
///   3. **Symptom check-in** — a tracking feature, moved into its own sheet
///      because it doesn't configure the processor.
struct ToneFinderView: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore

    private let minHz: Double = 1000
    private let maxHz: Double = 16_000

    @State private var lastConfirmedFrequency: Double?
    /// Captured pitch matches for the optional averaging aid. Tinnitus pitch
    /// matching is imprecise and octave-confusable, so a repeatable
    /// average/range is more honest than a single "definitive" number.
    @State private var matches: [Double] = []
    /// Fine-tune step size (Hz) for the − / + controls.
    @State private var stepHz: Int = 10
    /// Briefly highlights the notch card right after "Use this pitch", so the
    /// cause (finder) and effect (notch) read as connected.
    @State private var highlightNotch = false
    @State private var showCheckIn = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                introCard
                step1Level
                step2Sweep
                step3Compare
                step4Use
                notchSection
                checkInFooter
                disclaimer
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Tinnitus Tools")
        .onChange(of: lastConfirmedFrequency) { _, newValue in
            guard newValue != nil else { return }
            highlightNotch = true
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                highlightNotch = false
            }
        }
        .sheet(isPresented: $showCheckIn) {
            checkInSheet
        }
        .onDisappear { generator.stop() }
    }

    // MARK: - Intro

    private var introCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "tuningfork")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("Find the pitch closest to your ringing")
                    .font(.title3.weight(.semibold))
                Text("Work through the four steps below to match your tinnitus pitch, then use it to place the notch filter.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HelpContextButton(.tinnitusToneMatching, label: "tinnitus tone matching")
        }
    }

    // MARK: - Step 1 — level + transport (prominent stop while playing)

    private var step1Level: some View {
        stepCard(1, "Set a comfortable tone level") {
            HStack(spacing: 14) {
                Button {
                    generator.toggle()
                } label: {
                    Label(generator.isPlaying ? "Stop" : "Play tone",
                          systemImage: generator.isPlaying ? "stop.fill" : "play.fill")
                        .frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .tint(generator.isPlaying ? .red : .accentColor)
                .controlSize(.large)
                .keyboardShortcut(.space, modifiers: [])

                Image(systemName: "speaker.wave.1").foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(generator.amplitude) },
                        set: { generator.amplitude = Float($0) }
                    ),
                    in: 0.005...0.2
                )
                Image(systemName: "speaker.wave.3").foregroundStyle(.secondary)
                Text(amplitudeLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
            }
            Text("Start quiet — just loud enough to compare against your ringing — and stop the tone if it becomes uncomfortable. You're matching pitch, not loudness.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 2 — sweep + fine-tune

    private var step2Sweep: some View {
        stepCard(2, "Sweep for the closest pitch") {
            frequencyReadout
            sweepSurface
            stepControls
        }
    }

    private var frequencyReadout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(formattedFrequency)
                    .font(.system(size: 54, weight: .semibold, design: .rounded))
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tone frequency")
            .accessibilityValue("\(Int(currentHz.rounded())) hertz")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: nudge(stepHz)
                case .decrement: nudge(-stepHz)
                @unknown default: break
                }
            }
        }
        .frame(height: 120)
    }

    /// Step-size selector + two large − / + controls (replaces the old row of
    /// six fixed-increment buttons).
    private var stepControls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text("Step")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("Step", selection: $stepHz) {
                    Text("1 Hz").tag(1)
                    Text("10 Hz").tag(10)
                    Text("100 Hz").tag(100)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Spacer()

            Button { nudge(-stepHz) } label: {
                Image(systemName: "minus").frame(minWidth: 34)
            }
            .accessibilityLabel("Lower by \(stepHz) hertz")
            Text("\(stepHz) Hz")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .frame(minWidth: 56)
            Button { nudge(stepHz) } label: {
                Image(systemName: "plus").frame(minWidth: 34)
            }
            .accessibilityLabel("Raise by \(stepHz) hertz")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    // MARK: - Step 3 — compare nearby / octave

    private var step3Compare: some View {
        stepCard(3, "Compare slightly higher and lower") {
            Text("Small moves change the match. Nudge a little each way and settle on the closest. A tone one octave off can sound deceptively similar — check that too.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { nudgePercent(-0.03) } label: { Label("A bit lower", systemImage: "arrow.down") }
                Button { nudgePercent(0.03) } label: { Label("A bit higher", systemImage: "arrow.up") }
                Divider().frame(height: 18)
                Button { jumpOctave(-1) } label: { Label("Octave down", systemImage: "arrow.down.to.line") }
                Button { jumpOctave(1) } label: { Label("Octave up", systemImage: "arrow.up.to.line") }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            matchCaptureDisclosure
        }
    }

    /// Optional averaging aid — capture the pitch a few times and use the
    /// average. Collapsed by default so it doesn't crowd the primary flow.
    private var matchCaptureDisclosure: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
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
                    Spacer()
                }
                if matches.isEmpty {
                    Text("Capture the same pitch a few times to see a suggested average and range.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    matchChips
                    matchSummary
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Average a few matches (optional)", systemImage: "list.number")
                .font(.subheadline.weight(.medium))
        }
    }

    private var matchChips: some View {
        HStack(spacing: 6) {
            ForEach(Array(matches.enumerated()), id: \.offset) { idx, hz in
                Text("#\(idx + 1)  \(Int(hz)) Hz")
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
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
                generator.targetFrequencyHz = avg.rounded()
            } label: {
                Label("Move tone to the average", systemImage: "arrow.right.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Step 4 — use this pitch

    private var step4Use: some View {
        stepCard(4, "Use this pitch") {
            HStack(spacing: 12) {
                useThisPitchButton
                Spacer()
                if let confirmed = lastConfirmedFrequency {
                    Label("Notch set to \(Int(confirmed)) Hz", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
            }
            Text("Places the notch filter at \(Int(currentHz.rounded())) Hz and turns it on. You can fine-tune it in the notch below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Use this pitch" — single button for the linked notch, a Left/Right/Both
    /// menu when per-ear notches are on.
    @ViewBuilder private var useThisPitchButton: some View {
        let profile = audioState.activeProfile(in: profileStore)
        if profile?.separateNotch == true {
            Menu {
                Button("Left ear notch")  { setAsNotch(.left) }
                Button("Right ear notch") { setAsNotch(.right) }
                Divider()
                Button("Both notches")    { setAsNotch(.both) }
            } label: {
                Label("Use this pitch", systemImage: "bandage")
            }
            .menuStyle(.borderedButton)
            .controlSize(.large)
            .disabled(profile == nil)
        } else {
            Button {
                setAsNotch(.both)
            } label: {
                Label("Use this pitch", systemImage: "bandage")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(profile == nil)
        }
    }

    // MARK: - Notch configuration

    @ViewBuilder private var notchSection: some View {
        if let profile = audioState.activeProfile(in: profileStore) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Notch filter", systemImage: "bandage")
                        .font(.title3.weight(.semibold))
                    Spacer()
                }
                CorrectionConflictChip(crossLink: .audiogram)

                if profile.separateNotch {
                    // Per-ear (advanced): show both full controls + preview.
                    NotchPreviewView(
                        leftNotch: profile.leftNotch,
                        rightNotch: profile.rightNotch,
                        separate: true,
                        leftColor: audioState.preferences.leftEarColor,
                        rightColor: audioState.preferences.rightEarColor
                    )
                    separateToggleRow(profile)
                    NotchControlView(notch: leftNotchBinding(for: profile), title: "Left ear", symbol: "ear")
                    NotchControlView(notch: rightNotchBinding(for: profile), title: "Right ear", symbol: "ear")
                } else if profile.leftNotch.enabled {
                    // On (linked): preview + full controls.
                    NotchPreviewView(
                        leftNotch: profile.leftNotch,
                        rightNotch: profile.rightNotch,
                        separate: false,
                        leftColor: audioState.preferences.leftEarColor,
                        rightColor: audioState.preferences.rightEarColor
                    )
                    finderPitchHint(profile)
                    separateToggleRow(profile)
                    NotchControlView(notch: linkedNotchBinding(for: profile))
                } else {
                    // Off (linked): concise preview + enable, not a greyed form.
                    notchOffCard(profile)
                    separateToggleRow(profile)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(highlightNotch ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(highlightNotch ? Color.accentColor : .clear, lineWidth: 2)
            )
            .animation(.easeInOut(duration: 0.3), value: highlightNotch)
        }
    }

    /// Compact card shown when the (linked) notch is off — a one-line preview
    /// of what it would do plus a single enable button at the finder's pitch,
    /// so the finder and notch stay visibly connected.
    private func notchOffCard(_ profile: HearingProfile) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "bandage")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Notch is off")
                    .font(.callout.weight(.semibold))
                Text("Turn it on to gently reduce a narrow band around \(Int(currentHz.rounded())) Hz — the pitch above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                setAsNotch(.both)
            } label: {
                Label("Enable at \(Int(currentHz.rounded())) Hz", systemImage: "power")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// When the notch is on but the finder has since moved, offer to snap the
    /// notch to the current tone — so "1,000 Hz above, notch at 4,000" never
    /// looks broken.
    @ViewBuilder private func finderPitchHint(_ profile: HearingProfile) -> some View {
        let notchHz = profile.leftNotch.frequencyHz
        if abs(notchHz - currentHz) >= 1 {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.circle")
                    .foregroundStyle(.tint)
                Text("Tone Finder is at \(Int(currentHz.rounded())) Hz; the notch is at \(Int(notchHz.rounded())) Hz.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Use this pitch") { setAsNotch(.both) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.06)))
        }
    }

    @ViewBuilder private func separateToggleRow(_ profile: HearingProfile) -> some View {
        HStack {
            Toggle("Adjust ears separately", isOn: Binding(
                get: { profile.separateNotch },
                set: { newValue in
                    var updated = profile
                    updated.separateNotch = newValue
                    if !newValue { updated.rightNotch = updated.leftNotch }
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

    // MARK: - Symptom check-in (tracking, moved to its own sheet)

    private var checkInFooter: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tinnitus check-in")
                    .font(.callout.weight(.semibold))
                Text("Track how bothersome it feels over time. This doesn't change the notch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                showCheckIn = true
            } label: {
                Label("Open check-in", systemImage: "square.and.pencil")
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.05)))
    }

    private var checkInSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Tinnitus check-in")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { showCheckIn = false }
                    .keyboardShortcut(.defaultAction)
            }
            TinnitusCheckInView(store: audioState.tinnitusCheckIns)
        }
        .padding(24)
        // Size to content (was a fixed 380 pt tall box with a lot of empty
        // space); a fixed width keeps the copy readable and the height hugs
        // the slider + trend.
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Disclaimer

    /// Contextual (kept): the red-flag "see a professional" note is
    /// timing-relevant on the tinnitus screen and stays. The general
    /// non-clinical statement and the deeper "when a notch helps / evidence"
    /// background move to the shared chip and the tinnitus Help article.
    private var disclaimer: some View {
        VStack(alignment: .leading, spacing: 12) {
            SafetyNote(
                text: "Pulsatile (heartbeat-like) tinnitus, a sudden change in one ear, new hearing loss, dizziness, or pain deserve medical evaluation — not more audio tweaking.",
                symbol: "stethoscope",
                tint: .orange
            )
            HealthSafetyChip()
        }
    }

    // MARK: - Step scaffold

    @ViewBuilder
    private func stepCard<Content: View>(_ number: Int, _ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.accentColor))
                Text(title)
                    .font(.headline)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: - Generator + notch plumbing

    private var generator: SineToneGenerator { audioState.audio.toneGenerator }
    private var currentHz: Double { generator.targetFrequencyHz }

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

    private enum NotchTarget { case left, right, both }

    private func setAsNotch(_ target: NotchTarget) {
        applyNotch(frequency: currentHz, target: target)
    }

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

    // MARK: - Helpers

    private var formattedFrequency: String { Int(currentHz.rounded()).formatted() }

    private var amplitudeLabel: String {
        let amp = Double(generator.amplitude)
        let rms = amp / 2.squareRoot()
        let dbfs = 20 * log10(max(rms, 1e-6))
        return String(format: "%.0f dBFS", dbfs)
    }

    private struct NoteApprox { let label: String; let detail: String }

    private var noteApproximation: NoteApprox {
        let semis = 12 * log2(currentHz / 440)
        let nearest = Int(semis.rounded())
        let cents = (semis - Double(nearest)) * 100
        let noteNames = ["A", "A#", "B", "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#"]
        let nameIdx = ((nearest % 12) + 12) % 12
        let absSemis = nearest + 9
        let octave = absSemis >= 0 ? absSemis / 12 : (absSemis - 11) / 12
        let centsString = String(format: "%+d¢", Int(cents.rounded()))
        return NoteApprox(label: "\(noteNames[nameIdx])\(octave)", detail: centsString)
    }

    private var majorTicks: [Double] { [1000, 2000, 4000, 8000, 16000] }
    private func formatTick(_ hz: Double) -> String { "\(Int(hz / 1000))k" }
    private var freqAxis: LogFreqAxis { LogFreqAxis(minHz: minHz, maxHz: maxHz) }
    private func xFor(hz: Double, width: CGFloat) -> CGFloat { freqAxis.x(forHz: hz, width: width) }
    private func hzFor(x: CGFloat, width: CGFloat) -> Double { freqAxis.hz(forX: x, width: width) }

    private func nudge(_ delta: Int) {
        generator.targetFrequencyHz = max(minHz, min(maxHz, generator.targetFrequencyHz + Double(delta)))
    }

    private func nudgePercent(_ fraction: Double) {
        generator.targetFrequencyHz = max(minHz, min(maxHz, generator.targetFrequencyHz * (1 + fraction)))
    }

    private func jumpOctave(_ direction: Int) {
        let factor = direction >= 0 ? 2.0 : 0.5
        generator.targetFrequencyHz = max(minHz, min(maxHz, generator.targetFrequencyHz * factor))
    }

    private func recordMatch() {
        guard matches.count < 6 else { return }
        matches.append(currentHz.rounded())
    }
}
