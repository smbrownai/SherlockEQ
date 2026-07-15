import SwiftUI

/// The Listening Check flow (phase3-make-correction-land.md §4): a guided,
/// per-ear threshold **estimate** at the audiogram frequencies using the
/// modified Hughson–Westlake staircase in `ListeningCheckSession`.
///
/// This view owns everything the pure state machine deliberately doesn't:
/// tone presentation (via the engine's `SineToneGenerator`, which bypasses
/// the EQ so the check measures the ear, not the correction), the 1.5 s
/// response window and inter-trial jitter, the volume-integrity pause, the
/// built-in-speakers gate, and the results → profile apply.
///
/// Framing discipline (Design note 4): "Listening Check", "estimate" —
/// never "hearing test", never a diagnostic claim.
struct ListeningCheckView: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case setup, testing, betweenEars, results
    }

    @State private var step: Step = .setup
    @State private var session: ListeningCheckSession?
    @State private var betterEar: BetterEar = .notSure
    /// Volume-integrity anchor (spec §4.3): the system volume at Begin.
    /// Any change mid-run pauses the check.
    @State private var volumeSnapshotDB: Double?
    @State private var startDeviceUID: String?
    @State private var pausedForVolume = false
    @State private var deviceChangedMessage: String?
    @State private var awaitingResponse = false
    @State private var trialTask: Task<Void, Never>?

    private enum BetterEar: String, CaseIterable, Identifiable {
        case left = "Left", right = "Right", notSure = "Not sure"
        var id: String { rawValue }
        var startEar: ListeningCheckSession.TestEar {
            self == .right ? .right : .left
        }
    }

    /// Volume drift tolerated before pausing — HAL listeners echo tiny
    /// float wobbles; anything beyond this is a real knob/keys change.
    private static let volumeToleranceDB = 0.5
    private static let responseWindow: TimeInterval = 1.5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch step {
            case .setup:       setupPage
            case .testing:     testingPage
            case .betweenEars: betweenEarsPage
            case .results:     resultsPage
            }
        }
        .padding(24)
        .frame(minWidth: 620, idealWidth: 640, minHeight: 520)
        .onDisappear { teardownTone() }
        .onChange(of: audioState.systemVolume.volumeDB) { _, _ in checkVolumeIntegrity() }
        .onChange(of: audioState.systemVolume.isMuted) { _, _ in checkVolumeIntegrity() }
        .onChange(of: audioState.tap.currentOutputDeviceUID) { _, new in
            handleDeviceChange(newUID: new)
        }
    }

    // MARK: - Setup

    @ViewBuilder private var setupPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Listening Check")
                .font(.title2.weight(.semibold))
            Text("A guided estimate of the quietest level you can hear at each audiogram frequency, per ear. Takes about five minutes. The result can power your hearing adjustment — no clinical audiogram needed.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let message = deviceChangedMessage {
                warningBox(message)
            }

            if audioState.tap.currentOutputDeviceIsBuiltIn {
                warningBox("Headphones are required. The built-in speakers can't present tones to one ear at a time, and room acoustics would swamp quiet tones. Connect headphones, then return here.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    bullet("Output device: \(audioState.tap.currentOutputDeviceName). Use the headphones you normally listen with.")
                    bullet("Find a quiet room — background noise raises every measured threshold.")
                    bullet("Set a comfortable volume NOW and leave it alone. Changing the volume mid-check pauses the test.")
                    bullet(calibrationStatusLine)
                }

                Divider()

                HStack(spacing: 12) {
                    Text("Which ear seems to hear better?")
                        .font(.callout)
                    Picker("", selection: $betterEar) {
                        ForEach(BetterEar.allCases) { ear in
                            Text(ear.rawValue).tag(ear)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                }
                Text("The check starts with the better ear — it's easier to learn the task on tones you can hear comfortably.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Text("This is an estimate made with your own headphones in your own room. It cannot diagnose anything. For persistent hearing concerns, see a hearing-care professional.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Begin") { begin() }
                    .buttonStyle(.borderedProminent)
                    .disabled(audioState.tap.currentOutputDeviceIsBuiltIn)
            }
        }
    }

    private var calibrationStatusLine: String {
        if case .active = audioState.volumeTrackingStatus {
            return "Playback calibration: anchored — the estimate's absolute scale is as good as it gets."
        }
        return "Playback calibration: not anchored — the estimate's shape will be right, but its absolute scale is rougher. Calibrate in Safe Listening for better results (optional)."
    }

    // MARK: - Testing

    @ViewBuilder private var testingPage: some View {
        let earName = currentTrialEarName
        VStack(spacing: 18) {
            HStack {
                Text("Testing \(earName) ear")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }
            }
            ProgressView(value: session?.progress ?? 0)

            Spacer()
            if pausedForVolume {
                pauseOverlay
            } else {
                Text("Press the button — or the space bar — the moment you hear the pulsing tone, even if it's very faint. Long silences are part of the test.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)

                Button {
                    heardPressed()
                } label: {
                    Text("I hear it")
                        .font(.title2.weight(.semibold))
                        .frame(width: 220, height: 90)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityHint("Press when you hear the pulsing tone.")
            }
            Spacer()
        }
    }

    @ViewBuilder private var pauseOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "pause.circle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("System volume changed — the check is paused.")
                .font(.callout.weight(.semibold))
            Text("Set the volume back to where it was to continue, or restart the check at the new volume.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Restart check") { restart() }
                Button("Resume") { resumeAfterVolume() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!volumeMatchesSnapshot)
            }
        }
        .frame(maxWidth: 420)
    }

    // MARK: - Between ears

    @ViewBuilder private var betweenEarsPage: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            if case .earComplete(let ear) = session?.phase {
                Text("\(ear.rawValue) ear done.")
                    .font(.title3.weight(.semibold))
            }
            Text("Same task for the other ear — press when you hear the pulses.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Continue") {
                session?.continueToNextEar()
                step = .testing
                presentCurrent()
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Results

    @ViewBuilder private var resultsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Results")
                    .font(.title2.weight(.semibold))

                if let session {
                    earResultBlock(session, ear: .left, color: audioState.preferences.leftEarColor)
                    earResultBlock(session, ear: .right, color: audioState.preferences.rightEarColor)
                }

                if hasUnmeasurable {
                    warningBox("Some frequencies couldn't be measured — no response even at this check's safety ceiling. Those points are left out of the adjustment. For losses in that range, an EQ alone may not fully restore clarity; a hearing professional can discuss additional options.")
                }

                Text("This is an estimate made with your own headphones in your own room. It cannot diagnose anything. Applying it derives an adjustment the same way manual audiogram entry does — starting gently and rising over three weeks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Discard") { dismiss() }
                    Button("Redo check") { restart() }
                    Spacer()
                    Button("Apply to \(activeProfileName)") { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasAnyThreshold)
                }
            }
        }
    }

    @ViewBuilder private func earResultBlock(
        _ session: ListeningCheckSession,
        ear: ListeningCheckSession.TestEar,
        color: Color
    ) -> some View {
        let points = session.estimatedThresholds(for: ear)
        VStack(alignment: .leading, spacing: 6) {
            Text("\(ear.rawValue) ear")
                .font(.subheadline.weight(.semibold))
            if points.isEmpty {
                Text("No measurable thresholds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                AudiogramChartView(thresholds: .constant(points), earColor: color)
                    .frame(height: 170)
                    .allowsHitTesting(false)
            }
            if let result = session.earResult(ear), result.lowReliability {
                warningBox("Low reliability: \(reliabilityReasons(result)). Consider redoing this ear in a quieter moment.")
            }
        }
    }

    private func reliabilityReasons(_ result: ListeningCheckSession.EarResult) -> String {
        var reasons: [String] = []
        if result.aborted { reasons.append("the ear couldn't be familiarized at a safe level") }
        if result.falseAlarms > ListeningCheckSession.falseAlarmLimit {
            reasons.append("\(result.falseAlarms) responses during silent intervals")
        }
        if let delta = result.retestDeltaDB, abs(delta) > ListeningCheckSession.retestToleranceDB {
            reasons.append("the 1 kHz retest differed by \(Int(abs(delta))) dB")
        }
        if result.hitTrialCap { reasons.append("one frequency needed too many trials") }
        return reasons.joined(separator: "; ")
    }

    // MARK: - Flow control

    private func begin() {
        deviceChangedMessage = nil
        volumeSnapshotDB = audioState.systemVolume.volumeDB
        startDeviceUID = audioState.tap.currentOutputDeviceUID
        let offset = audioState.effectiveCalibrationOffsetDBA
        var newSession = ListeningCheckSession(
            config: .init(
                ceilingDBFS: ListeningCheckSession.Config.safetyCeilingDBFS(
                    effectiveCalibrationOffsetDBA: offset),
                effectiveCalibrationOffsetDBA: offset
            )
        )
        newSession.begin(firstEar: betterEar.startEar)
        session = newSession
        pausedForVolume = false
        step = .testing
        presentCurrent()
    }

    private func restart() {
        trialTask?.cancel()
        teardownTone()
        session = nil
        pausedForVolume = false
        awaitingResponse = false
        step = .setup
    }

    /// Present the state machine's current trial: inter-trial jitter (so
    /// responses can't ride a rhythm), then tone on (real trials) or
    /// silence (catch trials), then the response window. Window expiry =
    /// "not heard".
    private func presentCurrent() {
        guard let current = session, case .presenting(let trial) = current.phase else {
            syncStepWithPhase()
            return
        }
        trialTask?.cancel()
        trialTask = Task { @MainActor in
            let jitter = Double.random(in: 0.35...0.8)
            try? await Task.sleep(nanoseconds: UInt64(jitter * 1_000_000_000))
            guard !Task.isCancelled, !pausedForVolume else { return }

            let generator = audioState.audio.toneGenerator
            if !trial.isCatch {
                generator.targetFrequencyHz = trial.frequencyHz
                // Peak-amplitude convention, matching the calibration tone's
                // dBFS definition (see the §4.4 anchor math).
                generator.amplitude = Float(pow(10.0, trial.levelDBFS / 20.0))
                generator.setChannels(left: trial.ear == .left, right: trial.ear == .right)
                generator.pulsed = true
                generator.start()
            }
            awaitingResponse = true
            try? await Task.sleep(nanoseconds: UInt64(Self.responseWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            awaitingResponse = false
            generator.stop()
            session?.respond(heard: false)
            presentCurrent()
        }
    }

    private func heardPressed() {
        guard awaitingResponse else { return }
        trialTask?.cancel()
        awaitingResponse = false
        audioState.audio.toneGenerator.stop()
        session?.respond(heard: true)
        presentCurrent()
    }

    private func syncStepWithPhase() {
        guard let session else { return }
        switch session.phase {
        case .earComplete:
            teardownTone()
            step = .betweenEars
        case .finished:
            teardownTone()
            step = .results
        default:
            break
        }
    }

    // MARK: - Integrity guards

    private var volumeMatchesSnapshot: Bool {
        guard let snapshot = volumeSnapshotDB,
              let current = audioState.systemVolume.volumeDB else { return false }
        return abs(current - snapshot) <= Self.volumeToleranceDB
            && !audioState.systemVolume.isMuted
    }

    private func checkVolumeIntegrity() {
        guard step == .testing, !pausedForVolume else { return }
        guard volumeSnapshotDB != nil else { return }
        if !volumeMatchesSnapshot {
            pausedForVolume = true
            trialTask?.cancel()
            awaitingResponse = false
            audioState.audio.toneGenerator.stop()
        }
    }

    private func resumeAfterVolume() {
        guard volumeMatchesSnapshot else { return }
        pausedForVolume = false
        // The unanswered trial is still the machine's current phase —
        // re-present it; nothing was recorded for it.
        presentCurrent()
    }

    private func handleDeviceChange(newUID: String?) {
        guard step == .testing || step == .betweenEars,
              newUID != startDeviceUID else { return }
        // A different transducer invalidates every threshold measured so
        // far — hard stop back to setup, with the reason shown.
        restart()
        deviceChangedMessage = "The output device changed mid-check, which invalidates the levels measured so far. Reconnect the headphones you started with (or start over on the new ones)."
    }

    // MARK: - Apply / teardown

    private var activeProfileName: String {
        audioState.activeProfile(in: profileStore)?.name ?? "profile"
    }

    private var hasAnyThreshold: Bool {
        guard let session else { return false }
        return !session.estimatedThresholds(for: .left).isEmpty
            || !session.estimatedThresholds(for: .right).isEmpty
    }

    private var hasUnmeasurable: Bool {
        guard let session else { return false }
        return session.completedEars.contains { ear in
            ear.frequencyResults.contains { $0.thresholdDBFS == nil }
        }
    }

    private func apply() {
        guard let session,
              var profile = audioState.activeProfile(in: profileStore) else { return }
        profile.applyMeasuredAudiogram(
            left: session.estimatedThresholds(for: .left),
            right: session.estimatedThresholds(for: .right),
            source: .listeningCheck
        )
        try? profileStore.save(profile, actionName: "Apply Listening Check")
        dismiss()
    }

    private func teardownTone() {
        trialTask?.cancel()
        let generator = audioState.audio.toneGenerator
        generator.stop()
        generator.pulsed = false
        generator.setChannels(left: true, right: true)
        // Back to the Tone Finder's safe default level.
        generator.amplitude = 0.04
    }

    // MARK: - Small pieces

    @ViewBuilder private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func warningBox(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35)))
        .accessibilityElement(children: .combine)
    }

    private var currentTrialEarName: String {
        if let session, case .presenting(let trial) = session.phase {
            return trial.ear.rawValue.lowercased()
        }
        return ""
    }
}
