import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var tap = CATapEngineHolder()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AuditumEQ — CATapEngine smoke test")
                .font(.headline)

            labeled("State", value: stateLabel)
            labeled("Permission", value: (tap.engine?.permissionGranted ?? false) ? "granted" : "not granted")
            labeled("Output device ID", value: "\(tap.engine?.currentOutputDeviceID ?? 0)")
            labeled("Tap format", value: tap.engine?.tapFormat.map { "\(Int($0.sampleRate)) Hz · \($0.channelCount) ch" } ?? "—")

            HStack {
                Button("Request permission & start") {
                    Task { await tap.engine?.requestPermissionAndStart() }
                }
                .disabled(tap.engine == nil)

                Button("Stop") {
                    tap.engine?.stop()
                }
                .disabled(tap.engine == nil)
            }

            if let message = errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 240)
    }

    private func labeled(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
            Text(value).monospaced()
        }
    }

    private var stateLabel: String {
        guard let s = tap.engine?.state else { return "unavailable on this macOS version" }
        switch s {
        case .idle: return "idle"
        case .awaitingPermission: return "awaiting permission"
        case .permissionDenied: return "permission denied — grant in System Settings"
        case .starting: return "starting"
        case .running: return "running"
        case .failed(let m): return "failed: \(m)"
        }
    }

    private var errorMessage: String? {
        guard let s = tap.engine?.state, case .failed(let m) = s else { return nil }
        return m
    }
}

@MainActor
private final class CATapEngineHolder: ObservableObject {
    @Published var engine: CATapEngine?
    private var bag = Set<AnyCancellable>()

    init() {
        if #available(macOS 14.2, *) {
            let e = CATapEngine()
            self.engine = e
            e.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }.store(in: &bag)
        }
    }
}

#Preview {
    ContentView()
}
