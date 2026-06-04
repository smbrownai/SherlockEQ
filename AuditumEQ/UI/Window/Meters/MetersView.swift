import SwiftUI

/// Stereo meters page. Shows the vectorscope by default; an unmarked
/// secret double-tap on the section title flips to the analog VU
/// meter easter egg.
struct MetersView: View {
    @EnvironmentObject private var audioState: AudioState
    @AppStorage("auditumeq.metersAnalogMode") private var analogMode: Bool = false
    @State private var titleTapCount: Int = 0
    @State private var lastTapAt: Date = .distantPast

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if analogMode {
                    analogCard
                } else {
                    vectorscopeCard
                }
                tipFooter
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Meters")
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: analogMode ? "speedometer" : "scope")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(analogMode ? "Analog VU" : "Vectorscope")
                    .font(.title3.weight(.semibold))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 3, perform: toggleEasterEgg)
                Text(analogMode
                     ? "Tap the title three times to switch back."
                     : "Stereo phase scope — in-phase mono content reads vertical, anti-phase horizontal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var vectorscopeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            VectorscopeView(monitor: audioState.stereoMonitor)
                .frame(maxWidth: 460)
            peakReadout
        }
    }

    private var peakReadout: some View {
        // Wrapper subview that observes the monitor directly so the text
        // updates at the meter rate without re-rendering the canvas above.
        StereoPeakReadout(monitor: audioState.stereoMonitor)
            .padding(.top, 4)
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

    /// Inline subview so the surrounding MetersView body doesn't observe
    /// the monitor directly and re-render the header / canvases on every
    /// peak update.
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

    private func legendDot(_ color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var tipFooter: some View {
        Text(analogMode
             ? "(Hint: triple-tap the title to flip back to the modern scope.)"
             : "")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    /// Triple-tap title toggles the easter-egg state. The 3-count modifier
    /// on the gesture handles the timing; we just flip the flag.
    private func toggleEasterEgg() {
        analogMode.toggle()
    }
}
