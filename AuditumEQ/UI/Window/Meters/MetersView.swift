import SwiftUI

// MARK: - Dormant feature
//
// MetersView is no longer wired into the user-facing sidebar navigation
// (see SidebarSection — the `.meters` case has been removed). Level
// monitoring + the L/R VU lives in `MonitorSidebar` on the right-hand
// side of the main window now, and that sidebar's triple-tap easter egg
// uses the same VectorscopeView / AnalogVUMeterView / WaveformView
// components that used to be hosted here.
//
// Both the view code and the surrounding component files (Vectorscope,
// AnalogVUMeter, Waveform) are kept in the project for two reasons:
//   1. `MonitorSidebar` reuses them directly for its easter-egg modes.
//   2. If the dedicated Meters page is ever revived as its own sidebar
//      destination, restoring it is one enum-case + one switch-case.
//
// Don't delete this file — its subviews are still active code paths.

/// Stereo meters page. Vectorscope is the default; triple-tapping the
/// section title cycles through Vectorscope → Analog VU → Waveform →
/// back to Vectorscope. The latter two are easter eggs / fun bonuses
/// rather than load-bearing diagnostics.
struct MetersView: View {
    @EnvironmentObject private var audioState: AudioState
    @AppStorage("auditumeq.metersMode") private var modeRaw: String = MetersMode.vectorscope.rawValue

    enum MetersMode: String, CaseIterable {
        case vectorscope
        case analogVU
        case waveform

        var title: String {
            switch self {
            case .vectorscope: return "Vectorscope"
            case .analogVU:    return "Analog VU"
            case .waveform:    return "Waveform"
            }
        }

        var symbol: String {
            switch self {
            case .vectorscope: return "scope"
            case .analogVU:    return "speedometer"
            case .waveform:    return "waveform.path"
            }
        }

        var subtitle: String {
            switch self {
            case .vectorscope:
                return "Stereo phase scope — in-phase mono content reads vertical, anti-phase horizontal."
            case .analogVU:
                return "Tap the title three times to switch modes."
            case .waveform:
                return "Time-domain oscilloscope, L on top, R on bottom. Triggered on a positive zero-cross."
            }
        }

        var next: MetersMode {
            switch self {
            case .vectorscope: return .analogVU
            case .analogVU:    return .waveform
            case .waveform:    return .vectorscope
            }
        }
    }

    private var mode: MetersMode {
        MetersMode(rawValue: modeRaw) ?? .vectorscope
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                content
                tipFooter
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Meters")
        // The StereoMonitor's 60 Hz display loop is gated on at least one
        // attached subscriber — it only spins while a Meters view is on
        // screen. When the user navigates away, the timer (and its 5
        // @Published mutations per tick) goes idle.
        .onAppear { audioState.stereoMonitor.subscribe() }
        .onDisappear { audioState.stereoMonitor.unsubscribe() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: mode.symbol)
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.title)
                    .font(.title3.weight(.semibold))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 3, perform: cycleMode)
                Text(mode.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .vectorscope: vectorscopeCard
        case .analogVU:    analogCard
        case .waveform:    waveformCard
        }
    }

    private var vectorscopeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            VectorscopeView(monitor: audioState.stereoMonitor)
                .frame(maxWidth: 460)
            StereoPeakReadout(monitor: audioState.stereoMonitor)
                .padding(.top, 4)
        }
    }

    private var analogCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            AnalogVUMeterView(monitor: audioState.stereoMonitor)
                .frame(maxWidth: 520)
            Text("Cosmetic — needles follow a damped RMS envelope so the inertia feels mechanical. The real listening-dose meters live in Safe Listening.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var waveformCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            WaveformView(
                monitor: audioState.stereoMonitor,
                earColor: audioState.leftEarColor,
                rightColor: audioState.rightEarColor
            )
            .frame(maxWidth: 620)
            Text("For fun. Triggered on a positive zero-cross in L so the trace appears to stand still during steady-state material.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var tipFooter: some View {
        Text(mode == .vectorscope
             ? ""
             : "(Hint: triple-tap the title to cycle to the next view.)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    /// Inline subview so MetersView's body doesn't observe the monitor
    /// directly — that would re-render the canvas on every needle update.
    private struct StereoPeakReadout: View {
        @ObservedObject var monitor: StereoMonitor

        var body: some View {
            HStack(spacing: 14) {
                legendDot(.white, label: "Centre = silence")
                legendDot(Color(red: 0.45, green: 1.0, blue: 0.55), label: "Live trace")
                Spacer()
                Text(String(format: "L %.0f  ·  R %.0f", monitor.leftPeak * 100, monitor.rightPeak * 100))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }

        private func legendDot(_ color: Color, label: String) -> some View {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func cycleMode() {
        modeRaw = mode.next.rawValue
    }
}
