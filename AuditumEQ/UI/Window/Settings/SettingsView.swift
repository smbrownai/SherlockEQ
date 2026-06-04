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
                startupSection
                outputSection
                limiterSection
                appearanceSection
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

    private var startupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Startup").font(.headline)
            sectionBox {
                HStack {
                    Toggle("Launch at login", isOn: $audioState.launchAtLoginEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Spacer()
                }
                Divider()
                Text("When enabled, AuditumEQ starts automatically when you log in and runs in the menu bar. You can revoke this in System Settings → General → Login Items.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            }
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

    private var limiterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Peak limiter").font(.headline)
            sectionBox {
                limiterParamRow(
                    label: "Attack",
                    value: audioState.limiterAttackMs,
                    range: 1.0...30.0,
                    defaultValue: 12.0,
                    format: { String(format: "%.1f ms", $0) },
                    set: { audioState.limiterAttackMs = $0 }
                )
                Divider()
                limiterParamRow(
                    label: "Decay",
                    value: audioState.limiterDecayMs,
                    range: 1.0...60.0,
                    defaultValue: 24.0,
                    format: { String(format: "%.1f ms", $0) },
                    set: { audioState.limiterDecayMs = $0 }
                )
                Divider()
                limiterParamRow(
                    label: "Pre-gain",
                    value: audioState.limiterPreGainDB,
                    range: -40...40,
                    defaultValue: 0,
                    format: { String(format: "%+.1f dB", $0) },
                    set: { audioState.limiterPreGainDB = $0 }
                )
                Divider()
                Text("Shorter attack catches sharp transients but adds distortion. Longer decay smooths out sustained signals at the cost of pumping. Pre-gain pushes the signal harder into the limiter before it triggers.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            }
        }
    }

    private func limiterParamRow(
        label: String,
        value: Double,
        range: ClosedRange<Double>,
        defaultValue: Double,
        format: @escaping (Double) -> String,
        set: @escaping (Double) -> Void
    ) -> some View {
        let isDefault = abs(value - defaultValue) < 0.05
        return HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range)
                .controlSize(.small)
            Text(format(value))
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
                .frame(width: 72, alignment: .trailing)
            Button {
                set(defaultValue)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Reset \(label.lowercased()) to default")
            .disabled(isDefault)
            .opacity(isDefault ? 0.35 : 1)
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Appearance").font(.headline)
            sectionBox {
                colorRow(
                    label: "Left ear",
                    binding: $audioState.leftEarColor,
                    defaultColor: AudioState.defaultLeftEarColor
                )
                Divider()
                colorRow(
                    label: "Right ear",
                    binding: $audioState.rightEarColor,
                    defaultColor: AudioState.defaultRightEarColor
                )
                Divider()
                Text("Colors used for the left/right curves, audiogram thresholds, and EQ band sliders. Helpful for users who can't distinguish the default blue/red.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            }
        }
    }

    private func colorRow(label: String, binding: Binding<Color>, defaultColor: Color) -> some View {
        let isDefault = binding.wrappedValue.hexString == defaultColor.hexString
        return HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            ColorPicker("", selection: binding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44)
            Text(binding.wrappedValue.hexString)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                binding.wrappedValue = defaultColor
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Reset \(label.lowercased()) color to default")
            .disabled(isDefault)
            .opacity(isDefault ? 0.35 : 1)
        }
    }

    private var placeholderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Still to come").font(.headline)
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
