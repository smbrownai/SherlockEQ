import SwiftUI

/// App-wide settings. Today: master output gain. Future (Session 17):
/// launch-at-login, global Reference Mode shortcut, device auto-switching,
/// AutoEQ library, profile backup location, acknowledgments.
struct SettingsView: View {
    @EnvironmentObject private var audioState: AudioState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                outputSection
                placeholderSection
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Settings")
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "gearshape")
                .font(.system(size: 32))
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings").font(.title2.weight(.semibold))
                Text("App-wide preferences").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Output").font(.headline)
            sectionBox {
                masterGainRow
                Divider()
                Text("Applied after the peak limiter — the limiter still catches summed peaks, so boost up to +12 dB is safe. Persists across launches.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            }
        }
    }

    private var masterGainRow: some View {
        let isZero = abs(audioState.masterGainDB) < 0.05
        return HStack {
            Text("Master gain")
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Slider(
                value: Binding(
                    get: { audioState.masterGainDB },
                    set: { audioState.masterGainDB = $0 }
                ),
                in: -60...12
            )
            .controlSize(.small)
            Text(gainLabel(audioState.masterGainDB))
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
                .frame(width: 72, alignment: .trailing)
            Button {
                audioState.masterGainDB = 0
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Reset master gain to 0 dB")
            .disabled(isZero)
            .opacity(isZero ? 0.35 : 1)
        }
    }

    private func gainLabel(_ db: Double) -> String {
        if db <= -59.9 { return "Muted" }
        if abs(db) < 0.05 { return "0.0 dB" }
        return String(format: "%+.1f dB", db)
    }

    private var placeholderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Coming in Session 17").font(.headline)
            sectionBox {
                Text("Launch at login, global Reference Mode shortcut, device auto-switching, AutoEQ library, profile backup location, acknowledgments.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func sectionBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}
