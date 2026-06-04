import SwiftUI

/// Detail surface for safe-listening (spec §8.3). Five blocks:
///   1. Live level meter — A-weighted dBA estimate, color-zoned.
///   2. Today's dose — big bar + percentage + remaining minutes.
///   3. Settings — ceiling (per active profile), warning threshold,
///      notification toggle, manual reset.
///   4. Educational disclaimer — what this estimate is and isn't.
///   5. 7-day history (placeholder — persistence lands in a focused
///      follow-up session).
struct SafeListeningView: View {
    @EnvironmentObject private var state: AudioState
    @EnvironmentObject private var profileStore: ProfileStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                liveLevelCard
                doseCard
                settingsCard
                historyCard
                disclaimerCard
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Safe Listening")
        // Safety: if the user navigates away while the calibration tone is
        // playing, kill it so they don't return to find a 1 kHz tone still
        // looping. Toggling the same flag is cheap if it's already off.
        .onDisappear {
            if state.calibrationToneEnabled {
                state.calibrationToneEnabled = false
            }
        }
    }

    // MARK: - Cards

    @ViewBuilder private var liveLevelCard: some View {
        card {
            cardHeader("Live level", systemImage: "waveform")
            LevelMeterView(levelDBA: state.safeListening.currentLevelDBA)
        }
    }

    @ViewBuilder private var doseCard: some View {
        card {
            cardHeader("Today's dose", systemImage: "shield.lefthalf.filled")
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(String(format: "%.1f%%", state.safeListening.sessionDose * 100))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(doseColor)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(state.safeListening.didCrossRedToday ? "Limit reached" :
                         state.safeListening.didCrossAmberToday ? "Approaching limit" :
                         "Under safe limit")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(doseColor)
                    if let mins = state.safeListening.remainingMinutes {
                        Text(formatRemaining(mins))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Level under threshold")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(doseColor)
                        .frame(width: max(0, geo.size.width * min(1, state.safeListening.sessionDose)))
                        .animation(.easeOut(duration: 0.2), value: state.safeListening.sessionDose)
                    Rectangle()
                        .fill(Color.orange.opacity(0.3))
                        .frame(width: 1)
                        .offset(x: geo.size.width * 0.8)
                    Rectangle()
                        .fill(Color.red.opacity(0.4))
                        .frame(width: 1)
                        .offset(x: geo.size.width)
                }
            }
            .frame(height: 14)

            HStack {
                Text("0 %").font(.caption2.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text("Warn (80 %)").font(.caption2.monospaced()).foregroundStyle(.orange)
                Spacer()
                Text("Limit (100 %)").font(.caption2.monospaced()).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var settingsCard: some View {
        card {
            cardHeader("Settings", systemImage: "slider.horizontal.3")

            if let profile = state.activeProfile(in: profileStore) {
                sliderRow(
                    "Ceiling (active profile)",
                    value: profile.safeListeningCeilingDB,
                    range: 70...100,
                    format: { String(format: "%.0f dBA", $0) },
                    set: { newValue in
                        var copy = profile
                        copy.safeListeningCeilingDB = newValue
                        try? profileStore.save(copy)
                    }
                )
                Text("Ceiling lives on each profile — switching profiles can change this.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("No active profile — make one active in the Profiles section to set a ceiling.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            sliderRow(
                "Quiet threshold",
                value: state.safeListening.quietThresholdDBA,
                range: 30...70,
                format: { String(format: "%.0f dBA", $0) },
                set: { state.safeListening.quietThresholdDBA = $0 }
            )
            Text("Below this level, AuditumEQ stops counting remaining time and treats sustained quiet as a break.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Divider()

            sliderRow(
                "Playback calibration",
                value: state.calibrationOffsetDBA,
                range: 80...115,
                format: { String(format: "%.0f dB SPL @ 0 dBFS", $0) },
                set: { state.calibrationOffsetDBA = $0 }
            )
            Text("The dB SPL produced at your ear when a full-scale (0 dBFS) digital sample plays through your current output device at your usual volume. Used to convert dBFS into dBA for dose tracking AND to anchor the Loudness lens's safety overlay to real SPL. Default 100 is a rough estimate for consumer headphones at moderate volume — for accurate values use the reference tone below.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            calibrationToneRow

            Divider()

            Toggle("Send notifications at 80 % and 100 %", isOn: Binding(
                get: { state.safeListening.notificationsEnabled },
                set: { state.safeListening.notificationsEnabled = $0 }
            ))
            .toggleStyle(.switch)

            HStack {
                Spacer()
                Button(role: .destructive) {
                    state.safeListening.resetDose()
                } label: {
                    Label("Reset today's dose", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }

    /// Local state for the meter-reading text field — kept here instead of
    /// pushed into AudioState because it's a transient UI value, not a
    /// persisted setting. The persisted value is `calibrationOffsetDBA`,
    /// which we recompute from this reading + the tone's known dBFS level.
    @State private var meterReadingText: String = ""

    @ViewBuilder private var calibrationToneRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    state.calibrationToneEnabled.toggle()
                } label: {
                    Label(
                        state.calibrationToneEnabled ? "Stop 1 kHz tone" : "Play 1 kHz tone",
                        systemImage: state.calibrationToneEnabled ? "stop.fill" : "play.fill"
                    )
                }
                .buttonStyle(.bordered)
                .tint(state.calibrationToneEnabled ? .red : .accentColor)

                Text(String(format: "Tone level: %.0f dBFS",
                            Double(state.calibrationToneLevelDBFS)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()
            }

            HStack(spacing: 8) {
                Text("Meter reading")
                    .font(.callout)
                    .frame(width: 110, alignment: .leading)
                TextField("e.g. 78", text: $meterReadingText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .monospacedDigit()
                Text("dBA")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Apply") {
                    applyMeterReading()
                }
                .buttonStyle(.borderedProminent)
                .disabled(parsedMeterReading == nil)
                Spacer()
            }

            Text("Play the tone with your usual output device at your usual volume. Hold a phone-based SPL meter (NIOSH SLM is recommended on iPhone — it's been NIOSH-validated within ±2 dB) at your listening position. Type the dBA reading and tap Apply — the slider above will jump to the matching calibration. For headphones, cup the earcup over the phone mic; results are within a few dB. Don't forget to stop the tone before measuring music!")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `nil` when the field is empty or unparseable. Constrained to a
    /// sensible dBA range (40–130) so junk input doesn't slide through.
    private var parsedMeterReading: Double? {
        let trimmed = meterReadingText.trimmingCharacters(in: .whitespaces)
        guard let v = Double(trimmed), v >= 40, v <= 130 else { return nil }
        return v
    }

    private func applyMeterReading() {
        guard let reading = parsedMeterReading else { return }
        // The tone plays at `calibrationToneLevelDBFS` (negative dBFS). The
        // slider stores "dB SPL at 0 dBFS." So we ADD the tone's absolute
        // dBFS level to the meter reading: a tone at -12 dBFS measured at
        // 78 dBA implies 90 dB SPL at 0 dBFS.
        let toneOffset = Double(abs(state.calibrationToneLevelDBFS))
        let inferred = reading + toneOffset
        // Clamp to the slider's published range so we never silently push
        // a value the slider would reject.
        state.calibrationOffsetDBA = min(115, max(80, inferred))
    }

    @ViewBuilder private var historyCard: some View {
        card {
            cardHeader("7-day history", systemImage: "calendar")
            HStack {
                Text("Daily dose history is captured at the midnight rollover.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text("Persistence + chart wiring lands in a focused follow-up. Today's dose is shown above.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var disclaimerCard: some View {
        card {
            cardHeader("About this estimate", systemImage: "info.circle")
            VStack(alignment: .leading, spacing: 8) {
                bullet("Loudness is estimated from the digital signal level, not measured at your ear. Actual SPL depends on your hardware, headphone fit, and system volume.")
                bullet("Dose uses the NIOSH 3 dB exchange rate: 85 dBA over 8 hours is 100 %; every +3 dBA halves the safe duration.")
                bullet("AuditumEQ is not a medical device and makes no diagnostic claims. The dose meter is a daily-listening guide, not a clinical reading.")
                Link(destination: URL(string: "https://www.cdc.gov/niosh/topics/noise/")!) {
                    Label("NIOSH noise & hearing-loss prevention", systemImage: "arrow.up.right.square")
                        .font(.callout)
                }
            }
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func cardHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
    }

    @ViewBuilder
    private func sliderRow(
        _ label: String,
        value: Double,
        range: ClosedRange<Double>,
        format: @escaping (Double) -> String,
        set: @escaping (Double) -> Void
    ) -> some View {
        HStack {
            Text(label)
                .frame(width: 200, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range)
                .controlSize(.small)
            Text(format(value))
                .font(.callout.monospaced())
                .frame(width: 72, alignment: .trailing)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").font(.body)
            Text(text).font(.callout)
        }
    }

    private func formatRemaining(_ minutes: Double) -> String {
        // Past 24 hours the exact number stops being meaningful — the
        // user has all day at this level. Collapse to a plain label.
        if minutes >= 24 * 60 { return "All day remaining" }
        if minutes >= 60 {
            let h = Int(minutes) / 60
            let m = Int(minutes) % 60
            return "\(h)h \(m)m remaining"
        }
        return "\(Int(minutes))m remaining"
    }

    private var doseColor: Color {
        let d = state.safeListening.sessionDose
        if state.safeListening.didCrossRedToday || d >= 1.0 { return .red }
        if state.safeListening.didCrossAmberToday || d >= 0.8 { return .orange }
        return .green
    }
}
