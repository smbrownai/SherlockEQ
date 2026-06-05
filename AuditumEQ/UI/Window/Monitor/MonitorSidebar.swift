import SwiftUI

/// Right-hand monitoring sidebar — visible alongside every main-window
/// tab so users get persistent level / dose awareness while editing
/// their EQ, browsing profiles, calibrating, etc. Dismissible via the
/// toolbar toggle in `MainWindowView` and the visibility flag
/// `monitorSidebarVisible` persisted in @AppStorage.
///
/// Contents (top → bottom):
///   1. Output level VU — vertical L/R peak meter. Triple-tap the
///      header to cycle through Digital → Analog VU → Vectorscope →
///      Waveform display modes. The three secondary modes preserve the
///      easter-egg behaviours from the (now-removed) Meters tab.
///   2. Volume slider — master gain (post-EQ, pre-output). −60 ... +12 dB.
///   3. Balance slider — active profile's stereo balance. Includes a
///      recenter button. Editing here is the same as editing in
///      ProfileDetailView's balance row.
///   4. Dose mini-bar — today's NIOSH dose as a thin green/amber/red
///      capsule, mirroring Safe Listening's dose card at a glance.
struct MonitorSidebar: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore

    @State private var displayMode: DisplayMode = .digital

    enum DisplayMode: String, CaseIterable {
        case digital, analog, vectorscope, waveform

        var label: String {
            switch self {
            case .digital:     return "Output level"
            case .analog:      return "Analog VU"
            case .vectorscope: return "Vectorscope"
            case .waveform:    return "Waveform"
            }
        }

        var next: DisplayMode {
            let all = Self.allCases
            let nextIdx = (all.firstIndex(of: self)! + 1) % all.count
            return all[nextIdx]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            vuPanel
            Divider()
            volumeSection
            balanceSection
            Divider()
            doseSection
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(NSColor.windowBackgroundColor))
        // The stereo monitor's 60 Hz display loop is refcount-gated —
        // subscribe on appear so the VU updates while this sidebar is
        // visible, unsubscribe on disappear so the timer goes idle when
        // the user has dismissed the sidebar via the toolbar toggle.
        .onAppear { audioState.stereoMonitor.subscribe() }
        .onDisappear { audioState.stereoMonitor.unsubscribe() }
    }

    // MARK: - VU panel

    @ViewBuilder private var vuPanel: some View {
        VStack(spacing: 8) {
            Text(displayMode.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 3) { displayMode = displayMode.next }
                .help("Triple-tap to cycle display modes.")

            switch displayMode {
            case .digital:
                DigitalLRMeter(
                    monitor: audioState.stereoMonitor,
                    calibrationOffsetDBA: audioState.calibrationOffsetDBA
                )
                .frame(height: 180)
            case .analog:
                // Stacked layout for the narrow sidebar — two dials side-
                // by-side would each be ~85pt wide, too small to read the
                // dial markings. Vertical stacking gives each dial a
                // comfortable ~110pt height at aspect 1.6.
                AnalogVUMeter(
                    monitor: audioState.stereoMonitor,
                    mode: .stereo,
                    calibration: .standardDigital(),
                    vertical: true
                )
                .frame(height: 240)
            case .vectorscope:
                VectorscopeView(monitor: audioState.stereoMonitor)
                    .frame(height: 180)
            case .waveform:
                WaveformView(
                    monitor: audioState.stereoMonitor,
                    earColor: audioState.leftEarColor,
                    rightColor: audioState.rightEarColor
                )
                .frame(height: 180)
            }
        }
    }

    // MARK: - Volume

    @ViewBuilder private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Master Gain")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(formatGain(audioState.masterGainDB))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { audioState.masterGainDB },
                        set: { audioState.masterGainDB = $0 }
                    ),
                    in: -60...12
                )
                .controlSize(.small)
                Button {
                    audioState.masterGainDB = 0
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("Reset master gain to 0 dB")
            }
        }
    }

    // MARK: - Balance

    @ViewBuilder private var balanceSection: some View {
        if let profile = audioState.activeProfile(in: profileStore) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Balance")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(balanceLabel(profile.balance))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Slider(
                        value: Binding(
                            get: { profile.balance },
                            set: { newValue in
                                var updated = profile
                                updated.balance = newValue
                                try? profileStore.save(updated)
                            }
                        ),
                        in: -1...1
                    )
                    .controlSize(.small)
                    Button {
                        var updated = profile
                        updated.balance = 0
                        try? profileStore.save(updated)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Recenter balance")
                }
            }
        }
    }

    private func balanceLabel(_ b: Double) -> String {
        if abs(b) < 0.005 { return "Center" }
        if b > 0 { return String(format: "R %.0f%%", b * 100) }
        return String(format: "L %.0f%%", abs(b) * 100)
    }

    private func formatGain(_ dB: Double) -> String {
        let abs = Swift.abs(dB)
        if abs < 0.05 { return "0 dB" }
        return String(format: "%@%.1f dB", dB > 0 ? "+" : "−", abs)
    }

    // MARK: - Dose mini-bar

    @ViewBuilder private var doseSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Today's Dose")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(String(format: "%.0f %%", audioState.sessionDosePercent * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(doseColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(doseColor)
                        .frame(width: max(2, geo.size.width * min(1, audioState.sessionDosePercent)))
                }
            }
            .frame(height: 5)
        }
    }

    private var doseColor: Color {
        switch audioState.safeListening.doseSeverity {
        case .safe:  return .green
        case .amber: return .orange
        case .red:   return .red
        }
    }
}

// MARK: - Digital L/R meter

/// Vertical L/R peak meter — twin bars whose colour zones are derived
/// from the same dBA thresholds as Safe Listening's live level meter,
/// translated to dBFS via the user's playback calibration. A 70 dBA
/// "moderate" boundary maps to (70 − calibration) dBFS; an 85 "loud"
/// boundary maps to (85 − calibration) dBFS; a 95 "very loud" boundary
/// maps to (95 − calibration). The bar fills proportionally and the
/// portion of the fill within each dBA zone takes that zone's colour.
struct DigitalLRMeter: View {
    @ObservedObject var monitor: StereoMonitor
    /// SPL calibration in dB (0 dBFS → this many dB SPL at the listener).
    /// Determines where the colour boundaries land in dBFS terms.
    let calibrationOffsetDBA: Double

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            scaleColumn
            channelColumn(label: "L", peak: monitor.leftPeak)
            channelColumn(label: "R", peak: monitor.rightPeak)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func channelColumn(label: String, peak: Float) -> some View {
        VStack(spacing: 5) {
            Text(label)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(.secondary)
            meterBar(peak: peak)
                .frame(width: 18)
        }
    }

    /// dBFS scale alongside the L/R bars. Calibration-independent —
    /// these reference points sit at the same dBFS positions regardless
    /// of the user's calibration slider, so the visual position of each
    /// tick label corresponds directly to the bar's fill height for that
    /// dBFS level. The zone-boundary colours (yellow / red) shift with
    /// calibration; the dBFS reference scale doesn't.
    private var scaleColumn: some View {
        VStack(spacing: 5) {
            Text("dB")
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ForEach(Self.scaleTicks, id: \.self) { db in
                    let rawY = Self.y(forDB: db, height: geo.size.height)
                    // Clamp so the label centres stay inside the column
                    // rather than half-cropping at the very top / bottom.
                    let y = max(7, min(geo.size.height - 7, rawY))
                    Text("\(Int(db))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .position(x: geo.size.width / 2, y: y)
                }
            }
        }
        .frame(width: 22)
    }

    /// Reference dBFS values shown on the scale column. Picked to give a
    /// rough sense of fill height without crowding — finer detail isn't
    /// useful when the user's actual interest is "am I near the safety
    /// ceiling," which the colour zones already convey.
    private static let scaleTicks: [Double] = [0, -12, -30, -60]

    /// Map a dBFS value to a y-coordinate within a bar of the given
    /// height. 0 dB sits at the top (y = 0), -60 dB at the bottom
    /// (y = height). Bigger dB → smaller y.
    private static func y(forDB dB: Double, height: CGFloat) -> CGFloat {
        let clamped = max(-60.0, min(0.0, dB))
        return height * (1.0 - CGFloat((clamped + 60) / 60))
    }

    private func meterBar(peak: Float) -> some View {
        let peakDB = peak > 1e-5 ? 20 * log10(Double(peak)) : -60.0
        // Three-zone boundaries in dBFS, derived from Safe Listening's
        // 70 / 85 dBA thresholds via the user's calibration. Green up to
        // 70 dBA, yellow up to the 85 dBA NIOSH ceiling, red at or above
        // the ceiling. Same colour vocabulary as the dose meter so the
        // two surfaces agree at a glance.
        let yellowBoundary = 70 - calibrationOffsetDBA
        let redBoundary = 85 - calibrationOffsetDBA
        return GeometryReader { geo in
            let height = geo.size.height
            let yPeak = Self.y(forDB: peakDB, height: height)
            let yYellow = Self.y(forDB: yellowBoundary, height: height)
            let yRed = Self.y(forDB: redBoundary, height: height)

            // Per-section rendering — each rectangle is the intersection
            // of its zone with the part of the bar at-or-below the
            // current peak. A bar in the green zone draws ONLY green;
            // yellow / red rectangles compute non-positive height and
            // skip rendering.
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.18))

                // Green: max(yPeak, yYellow) → bottom.
                let greenTop = max(yPeak, yYellow)
                if greenTop < height {
                    Rectangle().fill(Self.greenColor)
                        .frame(height: height - greenTop)
                        .offset(y: greenTop)
                }
                // Yellow: max(yPeak, yRed) → yYellow.
                if yPeak < yYellow {
                    let yellowTop = max(yPeak, yRed)
                    if yellowTop < yYellow {
                        Rectangle().fill(Self.yellowColor)
                            .frame(height: yYellow - yellowTop)
                            .offset(y: yellowTop)
                    }
                }
                // Red: yPeak → yRed.
                if yPeak < yRed {
                    Rectangle().fill(Self.redColor)
                        .frame(height: yRed - yPeak)
                        .offset(y: yPeak)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }

    // Same colour palette as Safe Listening's LevelMeterView zones, so
    // the two surfaces look unified.
    private static let greenColor  = Color.green
    private static let yellowColor = Color.yellow
    private static let redColor    = Color.red
}
