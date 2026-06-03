import SwiftUI
import AVFoundation
import Combine

/// Diagnostic surface that lived in `ContentView` through Sessions 1–5.
/// Now scoped to the Debug sidebar entry of the main window. Will be trimmed
/// or removed once the user-facing equivalents (Safe Listening, Profiles
/// detail, etc.) exist and we no longer need raw counters.
struct DebugView: View {
    @EnvironmentObject private var state: AudioState
    @EnvironmentObject private var profileStore: ProfileStore
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
        labeled("Last error", value: state.audio.lastError ?? "—")
    }

    @ViewBuilder private var profilesSection: some View {
        Text("Profiles").font(.subheadline).foregroundStyle(.secondary)
        labeled("Loaded count", value: "\(profileStore.profiles.count)")
        labeled("Active profile", value: state.activeProfile(in: profileStore)?.name ?? "—")
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

    private var errorMessage: String? {
        if case .failed(let m) = state.tap.state { return m }
        return state.audio.lastError
    }
}
