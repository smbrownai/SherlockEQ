import SwiftUI
import AVFoundation

struct ContentView: View {
    @EnvironmentObject private var state: AudioState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("AuditumEQ — Session 2 (audio routing)")
                .font(.headline)

            tapSection
            Divider()
            engineSection
            Divider()
            controlsSection

            if let message = errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(22)
        .frame(minWidth: 520, minHeight: 380)
    }

    @ViewBuilder private var tapSection: some View {
        Text("Tap").font(.subheadline).foregroundStyle(.secondary)
        labeled("State", value: tapStateLabel)
        labeled("Permission", value: state.tap.permissionGranted ? "granted" : "not granted")
        labeled("Output device ID", value: "\(state.tap.currentOutputDeviceID)")
        labeled("Tap format", value: state.tap.tapFormat.map { "\(Int($0.sampleRate)) Hz · \($0.channelCount) ch" } ?? "—")
    }

    @ViewBuilder private var engineSection: some View {
        Text("AVAudioEngine").font(.subheadline).foregroundStyle(.secondary)
        labeled("Running", value: state.audio.isRunning ? "yes" : "no")
        labeled("Last error", value: state.audio.lastError ?? "—")
    }

    @ViewBuilder private var controlsSection: some View {
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
    }

    private func labeled(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value).monospaced()
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

#Preview {
    ContentView().environmentObject(AudioState())
}
