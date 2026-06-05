import SwiftUI
import AVFoundation
import Combine
import UserNotifications

/// Diagnostic surface that lived in `ContentView` through Sessions 1–5.
/// Now scoped to the Debug sidebar entry of the main window. Will be trimmed
/// or removed once the user-facing equivalents (Safe Listening, Profiles
/// detail, etc.) exist and we no longer need raw counters.
struct DebugView: View {
    @EnvironmentObject private var state: AudioState
    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var notifications = NotificationManager.shared
    @State private var tick = 0

    private let counterTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                tapSection
                Divider()
                engineSection
                Divider()
                profilesSection
                Divider()
                diagnosticsSection
                Divider()
                controlsSection

                if let message = errorMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onReceive(counterTimer) { _ in tick &+= 1 }
        .navigationTitle("Debug")
        // The analyzers' aWeightedDBFS / estimateDBA only update while the
        // FFT pipeline is running. We subscribe here so the Debug readouts
        // stay live without forcing a canvas tab to be open.
        .onAppear {
            state.spectrum.subscribe()
            state.preSpectrum.subscribe()
        }
        .onDisappear {
            state.spectrum.unsubscribe()
            state.preSpectrum.unsubscribe()
        }
    }

    @ViewBuilder private var tapSection: some View {
        Text("Tap").font(.subheadline).foregroundStyle(.secondary)
        labeled("State", value: tapStateLabel)
        labeled("Permission", value: state.tap.permissionGranted ? "granted" : "not granted")
        labeled("Output device", value: "\(state.tap.currentOutputDeviceName) (#\(state.tap.currentOutputDeviceID))")
        labeled("Tap format", value: state.tap.tapFormat.map { "\(Int($0.sampleRate)) Hz · \($0.channelCount) ch" } ?? "—")
    }

    @ViewBuilder private var engineSection: some View {
        Text("AVAudioEngine").font(.subheadline).foregroundStyle(.secondary)
        labeled("Running", value: state.audio.isRunning ? "yes" : "no")
        labeled("Output format", value: state.audio.outputFormatDescription)
        labeled("Spectrum tap", value: state.spectrum.isAttached ? "attached" : "—")
        labeled("Pre-EQ tap", value: state.preSpectrum.isAttached ? "attached" : "—")
        labeled("L render enters", value: "\(state.tap.preIngest.renderBlockEntries)")
        labeled("Pre-EQ callback fires", value: "\(state.tap.preIngest.callbackInvocations)")
        labeled("Post-EQ level (dBFS)", value: String(format: "%.1f", state.spectrum.aWeightedDBFS))
        labeled("Pre-EQ level (dBFS)", value: String(format: "%.1f", state.preSpectrum.aWeightedDBFS))
        labeled("Estimated dBA", value: String(format: "%.1f", state.spectrum.estimateDBA))
        labeled("Session dose", value: String(format: "%.1f %%", state.safeListening.sessionDose * 100))
        labeled("Remaining", value: state.safeListening.remainingMinutes.map { String(format: "%.1f min", $0) } ?? "—")
        labeled("Last error", value: state.audio.lastError ?? "—")
    }

    @ViewBuilder private var profilesSection: some View {
        Text("Profiles").font(.subheadline).foregroundStyle(.secondary)
        labeled("Loaded count", value: "\(profileStore.profiles.count)")
        labeled("Active profile", value: state.activeProfile(in: profileStore)?.name ?? "—")
        labeled("Last error", value: profileStore.lastError ?? "—")
        ForEach(profileStore.profiles) { profile in
            HStack {
                Image(systemName: profile.symbol).frame(width: 18)
                Text(profile.name).monospaced()
                Spacer()
                Text(profile.id.uuidString.prefix(8))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        Text("Storage: \(profileStore.storageDirectory.path)")
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
    }

    @ViewBuilder private var diagnosticsSection: some View {
        Text("Diagnostics (10 Hz, tick \(tick))").font(.subheadline).foregroundStyle(.secondary)
        labeled("Tap frames in", value: "\(state.tap.tapFramesIn.read())")
        labeled("L source frames out", value: "\(state.tap.leftSourceFramesOut.read())")
        labeled("R source frames out", value: "\(state.tap.rightSourceFramesOut.read())")
        labeled("Ring input peak (×1000)", value: "\(state.tap.ringInputPeakMilli.read())")
        labeled("Source output peak (×1000)", value: "\(state.tap.sourceOutputPeakMilli.read())")
        labeled("IOProc ABL buffers", value: "\(state.tap.ioProcBufferCount.read())")
        labeled("IOProc 1st mNumberChannels", value: "\(state.tap.ioProcFirstChannels.read())")
        labeled("IOProc 1st mDataByteSize", value: "\(state.tap.ioProcFirstByteSize.read())")
        labeled("Excluded process obj ID", value: "\(state.tap.excludedProcessObjectID.read())")
    }

    @ViewBuilder private var controlsSection: some View {
        Text("Controls").font(.subheadline).foregroundStyle(.secondary)

        HStack(spacing: 12) {
            Button("Start") { Task { await state.startAll() } }
                .keyboardShortcut(.defaultAction)
            Button("Stop") { state.stopAll() }
        }

        HStack(spacing: 12) {
            Button("Reset dose") { state.safeListening.resetDose() }
            Button("Force 80% (amber)") {
                state.safeListening.forceForTesting(dose: 0.80)
            }
            Button("Force 100% (red)") {
                state.safeListening.forceForTesting(dose: 1.0)
            }
        }

        Text("Notifications").font(.subheadline).foregroundStyle(.secondary)
        labeled("Authorization", value: authorizationLabel)
        HStack(spacing: 12) {
            Button("Request permission") {
                Task { await notifications.requestAuthorization() }
            }
            Button("Send test notification") {
                NotificationManager.shared.send(
                    title: "AuditumEQ test",
                    body: "If you see this banner, notifications are wired."
                )
            }
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        Toggle("Reference Mode (bypass EQ)", isOn: Binding(
            get: { state.referenceMode },
            set: { state.referenceMode = $0 }
        ))
        .toggleStyle(.switch)

        Toggle("Test curve — L: +6 dB @ 3 kHz, R: flat", isOn: Binding(
            get: { state.testCurveEnabled },
            set: { state.testCurveEnabled = $0 }
        ))
        .toggleStyle(.switch)

        Toggle("Test tone — 440 Hz sine through mainMixer (bypasses tap)", isOn: Binding(
            get: { state.testToneEnabled },
            set: { state.testToneEnabled = $0 }
        ))
        .toggleStyle(.switch)
    }

    private func labeled(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 200, alignment: .leading)
            Text(value).monospaced().lineLimit(1).truncationMode(.middle)
        }
    }

    private var tapStateLabel: String {
        switch state.tap.state {
        case .idle: return "idle"
        case .awaitingPermission: return "awaiting permission"
        case .permissionDenied: return "permission denied — grant in System Settings"
        case .starting: return "starting"
        case .running: return "running"
        case .failed(let m): return "failed: \(m)"
        }
    }

    private var authorizationLabel: String {
        switch notifications.authorizationStatus {
        case .notDetermined: return "not determined — click Request permission"
        case .denied: return "denied — enable in System Settings → Notifications"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown (\(notifications.authorizationStatus.rawValue))"
        }
    }

    private var errorMessage: String? {
        if case .failed(let m) = state.tap.state { return m }
        return state.audio.lastError
    }
}
