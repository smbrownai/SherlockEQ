import SwiftUI

/// Safe Listening detail surface. The top answers the two questions that
/// matter minute to minute — **how loud is it now** and **how much have I
/// used today** — with a calibration-confidence badge so the precision never
/// implies more measurement certainty than exists. Calibration itself (a
/// setup task, not a daily one) lives in its own sheet; quiet-threshold,
/// notifications, and the dose reset sit under Advanced.
struct SafeListeningView: View {
    @EnvironmentObject private var state: AudioState
    @EnvironmentObject private var profileStore: ProfileStore

    @State private var showCalibration = false
    @State private var confirmingReset = false

    /// Below this dBA the level reading is treated as "no audio" rather than a
    /// real quiet reading — matches the meter's own floor.
    private let audioFloorDBA: Double = 31

    private var isReceivingAudio: Bool {
        state.safeListening.currentLevelDBA >= audioFloorDBA
    }

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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HelpContextButton(.safetyLimits, label: "safety, limits, and listening responsibility")
            }
        }
        .sheet(isPresented: $showCalibration) { calibrationSheet }
        .confirmationDialog(
            "Reset today's exposure to 0 %?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset exposure", role: .destructive) { state.safeListening.resetDose() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the exposure counted so far today. It can't be undone.")
        }
        .onDisappear {
            if state.eqChain.calibrationToneEnabled {
                state.eqChain.calibrationToneEnabled = false
            }
        }
    }

    // MARK: - Q1: How loud is it now?

    @ViewBuilder private var liveLevelCard: some View {
        card {
            HStack {
                cardHeader("How loud is it now?", systemImage: "waveform")
                Spacer()
                calibrationBadge
            }
            LevelMeterView(
                levelDBA: state.safeListening.currentLevelDBA,
                isReceivingAudio: isReceivingAudio
            )
        }
    }

    /// Not calibrated / Approximate / Calibrated — placed by the live value so
    /// the reader knows how much to trust the number.
    private var calibrationBadge: some View {
        let c = calibrationConfidence
        return Label(c.label, systemImage: c.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(c.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(c.color.opacity(0.12)))
            .help(c.help)
    }

    private enum CalibrationConfidence {
        case notCalibrated, approximate, calibrated
        var label: String {
            switch self {
            case .notCalibrated: return "Not calibrated"
            case .approximate:   return "Approximate"
            case .calibrated:    return "Calibrated"
            }
        }
        var symbol: String {
            switch self {
            case .notCalibrated: return "questionmark.circle"
            case .approximate:   return "circle.dotted"
            case .calibrated:    return "checkmark.seal.fill"
            }
        }
        var color: Color {
            switch self {
            case .notCalibrated: return .secondary
            case .approximate:   return .orange
            case .calibrated:    return .green
            }
        }
        var help: String {
            switch self {
            case .notCalibrated: return "Levels use a rough default. Calibrate for accurate dBA."
            case .approximate:   return "Calibrated, but current conditions (volume unreadable or a different device) reduce confidence."
            case .calibrated:    return "Calibrated and tracking your system volume."
            }
        }
    }

    private var calibrationConfidence: CalibrationConfidence {
        guard state.hasUserCalibration else { return .notCalibrated }
        if case .active = state.volumeTrackingStatus { return .calibrated }
        return .approximate
    }

    // MARK: - Q2: How much have I used today?

    @ViewBuilder private var doseCard: some View {
        card {
            cardHeader("Today's exposure", systemImage: "shield.lefthalf.filled")
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(String(format: "%.0f%%", state.safeListening.sessionDose * 100))
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
                    remainingReadout
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(doseColor)
                        .frame(width: max(0, geo.size.width * min(1, state.safeListening.sessionDose)))
                        .animation(.easeOut(duration: 0.2), value: state.safeListening.sessionDose)
                    Rectangle().fill(Color.orange.opacity(0.3)).frame(width: 1).offset(x: geo.size.width * 0.8)
                    Rectangle().fill(Color.red.opacity(0.4)).frame(width: 1).offset(x: geo.size.width)
                }
            }
            .frame(height: 14)

            HStack {
                Text("0 %").font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text("Warn (80 %)").font(.caption.monospaced()).foregroundStyle(.orange)
                Spacer()
                Text("Limit (100 %)").font(.caption.monospaced()).foregroundStyle(.red)
            }
        }
    }

    /// Remaining safe time is the actionable figure — but only meaningful once
    /// calibrated. Otherwise defer to the dose percentage above.
    @ViewBuilder private var remainingReadout: some View {
        if state.hasUserCalibration, let mins = state.safeListening.remainingMinutes {
            Text(formatRemaining(mins))
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        } else if state.hasUserCalibration {
            Text("Level under threshold")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Calibrate to see time left")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Settings

    @ViewBuilder private var settingsCard: some View {
        card {
            cardHeader("Settings", systemImage: "slider.horizontal.3")

            if let profile = state.activeProfile(in: profileStore) {
                sliderRow(
                    "Listening limit",
                    scope: .profile,
                    value: profile.safeListeningCeilingDB,
                    range: 70...100,
                    format: { String(format: "%.0f dBA", $0) },
                    set: { newValue in
                        var copy = profile
                        copy.safeListeningCeilingDB = newValue
                        try? profileStore.save(copy)
                    }
                )
                Text("The level SherlockEQ treats as your daily limit. It lives on each profile — switching profiles can change it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("No active profile — make one active in the Profiles section to set a listening limit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            calibrationRow

            Divider()

            advancedDisclosure
        }
    }

    /// Short calibration entry point — the long explanation lives in the sheet.
    private var calibrationRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Calibrate for more accurate level estimates")
                    .font(.callout.weight(.medium))
                Text("Requires an SPL meter or supported phone app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showCalibration = true
            } label: {
                Label(state.hasUserCalibration ? "Recalibrate…" : "Calibrate…", systemImage: "target")
            }
        }
    }

    private var advancedDisclosure: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                sliderRow(
                    "Quiet threshold",
                    scope: .app,
                    value: state.safeListening.quietThresholdDBA,
                    range: 30...70,
                    format: { String(format: "%.0f dBA", $0) },
                    set: { state.safeListening.quietThresholdDBA = $0 }
                )
                Text("Below this level, SherlockEQ stops counting remaining time and treats sustained quiet as a break.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Send notifications at 80 % and 100 %", isOn: Binding(
                    get: { state.safeListening.notificationsEnabled },
                    set: { state.safeListening.notificationsEnabled = $0 }
                ))
                .toggleStyle(.switch)

                HStack {
                    Button {
                        confirmingReset = true
                    } label: {
                        Label("Reset today's exposure", systemImage: "arrow.counterclockwise")
                    }
                    .controlSize(.small)
                    Spacer()
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Advanced")
                .font(.subheadline.weight(.medium))
        }
    }

    // MARK: - Calibration sheet

    @State private var meterReadingText: String = ""

    private var calibrationSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Calibrate playback level")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button("Done") { showCalibration = false }
                        .keyboardShortcut(.defaultAction)
                }

                Text("Match SherlockEQ's dBA estimate to a real measurement so dose tracking and the safety overlay reflect your actual output. You'll need an SPL meter or a supported phone app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                sliderRow(
                    "Playback calibration",
                    scope: .device,
                    value: state.calibrationOffsetDBA,
                    range: 80...115,
                    format: { String(format: "%.0f dB SPL @ 0 dBFS", $0) },
                    set: { state.calibrationOffsetDBA = $0 }
                )

                volumeTrackingRow

                Divider()

                calibrationToneRow
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 460)
    }

    @ViewBuilder private var volumeTrackingRow: some View {
        let status = state.volumeTrackingStatus
        Label {
            Text(volumeTrackingDescription(for: status))
        } icon: {
            Image(systemName: volumeTrackingSymbol(for: status))
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func volumeTrackingDescription(for status: CalibrationVolumeAnchor.Status) -> String {
        switch status {
        case .active(let delta) where abs(delta) < 0.05:
            return String(localized: "System volume is tracked — currently at the calibrated volume.")
        case .active(let delta):
            return String(localized: "System volume is tracked — the estimate currently includes \(delta, format: FloatingPointFormatStyle<Double>().precision(.fractionLength(1)).sign(strategy: .always())) dB for the volume change since calibration.")
        case .muted:
            return String(localized: "Output is muted — no listening exposure is accumulating.")
        case .deviceMismatch:
            return String(localized: "Calibrated on a different output device — recalibrate to re-anchor volume tracking.")
        case .unavailable:
            return String(localized: "This output device doesn't expose its volume — the estimate assumes the volume from calibration time.")
        case .unanchored:
            return String(localized: "Adjust the calibration once to anchor it to your current volume — from then on, volume changes adjust the estimate automatically.")
        }
    }

    private func volumeTrackingSymbol(for status: CalibrationVolumeAnchor.Status) -> String {
        switch status {
        case .active:         return "speaker.wave.2"
        case .muted:          return "speaker.slash"
        case .deviceMismatch: return "arrow.triangle.2.circlepath"
        case .unavailable:    return "speaker.badge.exclamationmark"
        case .unanchored:     return "scope"
        }
    }

    @ViewBuilder private var calibrationToneRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    state.eqChain.calibrationToneEnabled.toggle()
                } label: {
                    Label(
                        state.eqChain.calibrationToneEnabled ? "Stop 1 kHz tone" : "Play 1 kHz tone",
                        systemImage: state.eqChain.calibrationToneEnabled ? "stop.fill" : "play.fill"
                    )
                }
                .buttonStyle(.bordered)
                .tint(state.eqChain.calibrationToneEnabled ? .red : .accentColor)

                Text(String(format: "Tone level: %.0f dBFS", Double(state.calibrationToneLevelDBFS)))
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
                Text("dBA").font(.callout).foregroundStyle(.secondary)
                Button("Apply") { applyMeterReading() }
                    .buttonStyle(.borderedProminent)
                    .disabled(parsedMeterReading == nil)
                Spacer()
            }

            Text("Play the tone with your usual output device at your usual volume. Hold a phone-based SPL meter (NIOSH SLM is recommended on iPhone — NIOSH-validated within ±2 dB) at your listening position. Type the dBA reading and tap Apply — the slider above jumps to the matching calibration. For headphones, cup the earcup over the phone mic; results are within a few dB. Stop the tone before measuring music.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var parsedMeterReading: Double? {
        let trimmed = meterReadingText.trimmingCharacters(in: .whitespaces)
        guard let v = Double(trimmed), v >= 40, v <= 130 else { return nil }
        return v
    }

    private func applyMeterReading() {
        guard let reading = parsedMeterReading else { return }
        let toneOffset = Double(abs(state.calibrationToneLevelDBFS))
        let inferred = reading + toneOffset
        state.calibrationOffsetDBA = min(115, max(80, inferred))
    }

    // MARK: - History + disclaimer

    @ViewBuilder private var historyCard: some View {
        card {
            cardHeader("7-day history", systemImage: "calendar")
            Text("Each day's peak dose, captured at the midnight rollover. Today reflects your exposure so far.")
                .font(.callout)
                .foregroundStyle(.secondary)
            DoseHistoryChart(history: state.doseHistory, tracker: state.safeListening)
                .padding(.top, 4)
        }
    }

    // Contextual (kept): how to read the estimate and dose — timing-relevant
    // to interpreting the numbers on this screen. The general "not a medical
    // device" statement moved to the shared chip → Health & Safety sheet.
    @ViewBuilder private var disclaimerCard: some View {
        card {
            cardHeader("About this estimate", systemImage: "info.circle")
            VStack(alignment: .leading, spacing: 8) {
                bullet("Loudness is estimated from the digital signal level, not measured at your ear. Actual SPL still depends on your hardware and headphone fit.")
                bullet("Dose uses the NIOSH 3 dB exchange rate: 85 dBA over 8 hours is 100 %; every +3 dBA halves the safe duration. It's a daily-listening guide, not a clinical reading.")
                Link(destination: URL(string: "https://www.cdc.gov/niosh/topics/noise/")!) {
                    Label("NIOSH noise & hearing-loss prevention", systemImage: "arrow.up.right.square")
                        .font(.callout)
                }
            }
        }
        HealthSafetyChip()
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
        scope: ControlScope? = nil,
        value: Double,
        range: ClosedRange<Double>,
        format: @escaping (Double) -> String,
        set: @escaping (Double) -> Void
    ) -> some View {
        HStack {
            HStack(spacing: 6) {
                Text(label)
                if let scope { ScopeBadge(scope: scope) }
            }
            .frame(width: 240, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range)
                .controlSize(.small)
            Text(format(value))
                .font(.callout.monospaced())
                .frame(width: 128, alignment: .trailing)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").font(.body)
            Text(text).font(.callout)
        }
    }

    private func formatRemaining(_ minutes: Double) -> String {
        if minutes >= 24 * 60 { return "All day remaining" }
        if minutes >= 60 {
            let h = Int(minutes) / 60
            let m = Int(minutes) % 60
            return "\(h)h \(m)m left"
        }
        return "\(Int(minutes))m left"
    }

    private var doseColor: Color {
        switch state.safeListening.doseSeverity {
        case .safe:  return .green
        case .amber: return .orange
        case .red:   return .red
        }
    }
}
