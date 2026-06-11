import SwiftUI

/// The Analog Control Unit — an optional, playful "front panel" for the
/// five adjustments people understand immediately: Volume, Balance, Bass,
/// Mid, Treble. It is a pure *view over* SherlockEQ's existing state:
///
///   • Volume  → `audioState.masterGainDB`
///   • Balance → active profile's `balance`
///   • Bass / Mid / Treble → the same Simple-EQ shelves `SimpleEQView` edits
///   • VU meters → the shared `AnalogVUMeter` + `StereoMonitor`
///   • Output  → read-only indicator of the current system output
///
/// No new DSP, no parallel state. Changes here flow through the same
/// `ProfileStore` / `EngineParameters` paths the rest of the app uses, so
/// edits made anywhere stay in sync both directions.
struct AnalogControlUnitView: View {
    @EnvironmentObject private var audioState: AudioState
    @EnvironmentObject private var profileStore: ProfileStore
    /// The one knob that reaches outside SherlockEQ: VOLUME drives the macOS
    /// system output level, not the app's internal gain.
    @StateObject private var systemVolume = SystemVolumeController()

    private var hasProfile: Bool {
        audioState.activeProfile(in: profileStore) != nil
    }

    var body: some View {
        ZStack {
            AnalogFaceplate()
            VStack(spacing: 12) {
                header
                HStack(alignment: .center, spacing: 16) {
                    AnalogVUMeter(
                        monitor: audioState.stereoMonitor,
                        mode: .stereo,
                        calibration: .standardDigital(),
                        showReadout: true
                    )
                    .frame(height: 138)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .recessed()

                    volumeColumn
                }

                knobRow
                footer
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 14)
        }
        .frame(minWidth: 700, idealWidth: 700, minHeight: 400, idealHeight: 400)
        .environment(\.colorScheme, .dark)
        .onAppear {
            audioState.stereoMonitor.subscribe()
            systemVolume.start()
        }
        .onDisappear {
            audioState.stereoMonitor.unsubscribe()
            systemVolume.stop()
        }
    }

    // MARK: Volume (system output) — the hero knob beside the meters

    private var volumeColumn: some View {
        VStack(spacing: 4) {
            AnalogKnob(
                title: "VOLUME",
                value: volumeBinding,
                range: 0...1,
                defaultValue: 0.5,
                step: 0.02,
                formatter: Self.percentLabel,
                accessibilityValue: Self.percentSpoken,
                size: 96,
                resettable: false
            )
            .disabled(!systemVolume.isAvailable)
            Text(systemVolume.isAvailable ? "SYSTEM" : "NO CONTROL")
                .font(.system(size: 8, weight: .semibold))
                .tracking(2)
                .foregroundStyle(AnalogTheme.engraveDim)
        }
        .frame(width: 118)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 2) {
            Text("SherlockEQ")
                .font(.system(size: 14, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(AnalogTheme.cream)
            Text("ANALOG CONTROL UNIT")
                .font(.system(size: 9, weight: .medium))
                .tracking(3)
                .foregroundStyle(AnalogTheme.engraveDim)
        }
        .shadow(color: .black.opacity(0.8), radius: 0, y: -0.5)
        .frame(maxWidth: .infinity)
    }

    // MARK: Knobs

    private var knobRow: some View {
        HStack(alignment: .top, spacing: 2) {
            AnalogKnob(
                title: "BALANCE",
                value: balanceBinding,
                range: -1...1,
                defaultValue: 0,
                step: 0.02,
                detentValue: 0,
                formatter: Self.balanceLabel,
                accessibilityValue: Self.balanceSpoken
            )
            .disabled(!hasProfile)
            hairline
            AnalogKnob(
                title: "BASS",
                value: eqBinding(frequencyHz: 250, bandwidth: 0.707, filterType: .lowShelf),
                range: -12...12, defaultValue: 0, step: 0.5, detentValue: 0,
                formatter: Self.dbLabel, accessibilityValue: Self.dbSpoken
            )
            .disabled(!hasProfile)
            AnalogKnob(
                title: "MID",
                value: eqBinding(frequencyHz: 1000, bandwidth: 1.8, filterType: .parametric),
                range: -12...12, defaultValue: 0, step: 0.5, detentValue: 0,
                formatter: Self.dbLabel, accessibilityValue: Self.dbSpoken
            )
            .disabled(!hasProfile)
            AnalogKnob(
                title: "TREBLE",
                value: eqBinding(frequencyHz: 5000, bandwidth: 0.707, filterType: .highShelf),
                range: -12...12, defaultValue: 0, step: 0.5, detentValue: 0,
                formatter: Self.dbLabel, accessibilityValue: Self.dbSpoken
            )
            .disabled(!hasProfile)
            hairline
            AnalogOutputIndicator(tap: audioState.tap)
        }
        .frame(maxWidth: .infinity)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(width: 1, height: 68)
            .padding(.horizontal, 8)
            .padding(.top, 12)
    }

    private var footer: some View {
        Text("VOLUME controls macOS output level · Balance & tone map to SherlockEQ")
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(AnalogTheme.engraveDim)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Bindings (views over existing state)

    /// VOLUME is the deliberate exception: it drives the macOS system output
    /// volume (see `SystemVolumeController`), not the app's internal gain or
    /// the Safe-Listening calibration.
    private var volumeBinding: Binding<Double> {
        Binding(
            get: { systemVolume.volume },
            set: { systemVolume.setVolume($0) }
        )
    }

    private var balanceBinding: Binding<Double> {
        Binding(
            get: { audioState.activeProfile(in: profileStore)?.balance ?? 0 },
            set: { newValue in
                guard var p = audioState.activeProfile(in: profileStore) else { return }
                p.balance = newValue
                try? profileStore.save(p)
            }
        )
    }

    /// Mirrors `SimpleEQView`: edits the shelf/parametric band at the given
    /// frequency on the active profile, honouring its `separateChannels`
    /// link the same way the Simple tab does. Reads the left ear as the
    /// representative value (identical to the linked Simple slider).
    private func eqBinding(frequencyHz: Double, bandwidth: Double, filterType: EQFilterType) -> Binding<Double> {
        Binding(
            get: {
                guard let p = audioState.activeProfile(in: profileStore) else { return 0 }
                return EQBandLookup.gain(at: frequencyHz, filterType: filterType, in: p.leftEar.bands)
            },
            set: { newValue in
                guard var p = audioState.activeProfile(in: profileStore) else { return }
                let link = !p.separateChannels
                EQBandLookup.mutateBands(of: &p, ear: .left, linkChannels: link) { bands in
                    EQBandLookup.setGain(newValue, at: frequencyHz, bandwidth: bandwidth, filterType: filterType, in: &bands)
                }
                try? profileStore.save(p)
            }
        )
    }

    // MARK: - Label formatters

    static func percentLabel(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }

    static func percentSpoken(_ v: Double) -> String {
        "\(Int((v * 100).rounded())) percent"
    }

    static func dbLabel(_ v: Double) -> String {
        if abs(v) < 0.05 { return "0 dB" }
        return String(format: "%@%.1f dB", v > 0 ? "+" : "\u{2212}", abs(v))
    }

    static func dbSpoken(_ v: Double) -> String {
        if abs(v) < 0.05 { return "0 decibels" }
        return String(format: "%@ %.1f decibels", v > 0 ? "plus" : "minus", abs(v))
    }

    static func balanceLabel(_ v: Double) -> String {
        if abs(v) < 0.005 { return "C" }
        let pct = Int((abs(v) * 100).rounded())
        return v < 0 ? "L \(pct)" : "R \(pct)"
    }

    static func balanceSpoken(_ v: Double) -> String {
        if abs(v) < 0.005 { return "centered" }
        let pct = Int((abs(v) * 100).rounded())
        return v < 0 ? "\(pct) percent left" : "\(pct) percent right"
    }
}

// MARK: - Output indicator (read-only)

/// Read-only "OUTPUT" strip: lamps the simplified category of the current
/// system output and shows the actual device name. SherlockEQ has no
/// device-selection API yet (the tap follows the system default output),
/// so this is intentionally an indicator, not a router — no unstable
/// routing is introduced just to satisfy the visual.
struct AnalogOutputIndicator: View {
    @ObservedObject var tap: CATapEngine

    private var deviceName: String { tap.currentOutputDeviceName }
    private var category: OutputCategory { OutputCategory(deviceName: deviceName) }

    var body: some View {
        VStack(spacing: 5) {
            Text("OUTPUT")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(AnalogTheme.engrave)

            HStack(spacing: 4) {
                ForEach(OutputCategory.allCases) { c in
                    AnalogPushButton(label: c.label, isActive: c == category)
                }
            }

            Text(deviceName)
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .foregroundStyle(AnalogTheme.engraveDim)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 200)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Output"))
        .accessibilityValue(Text("\(category.spoken), \(deviceName)"))
    }
}

/// A vintage round metal push button. Read-only here: the button for the
/// current output category reads as engaged (depressed + amber lamp); the
/// others sit raised. No routing — pressing does nothing.
private struct AnalogPushButton: View {
    let label: String
    let isActive: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Socket the button sits in.
                Circle()
                    .fill(Color.black.opacity(0.5))
                    .frame(width: 26, height: 26)
                    .blur(radius: 1.5)
                    .offset(y: 1)

                Circle()
                    .fill(isActive ? AnalogTheme.buttonPressed : AnalogTheme.buttonRaised)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(AnalogTheme.rim, lineWidth: 1))
                    .overlay {
                        if isActive {
                            Circle()
                                .fill(AnalogTheme.amber)
                                .frame(width: 5, height: 5)
                                .shadow(color: AnalogTheme.amber.opacity(0.9), radius: 3)
                        } else {
                            Ellipse()
                                .fill(Color.white.opacity(0.4))
                                .frame(width: 10, height: 4)
                                .offset(y: -4)
                                .blur(radius: 1.5)
                        }
                    }
                    .shadow(color: .black.opacity(isActive ? 0.6 : 0.4),
                            radius: isActive ? 1 : 3,
                            y: isActive ? 0 : 2)
            }
            .frame(width: 26, height: 26)

            Text(label)
                .font(.system(size: 7, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(isActive ? AnalogTheme.cream : AnalogTheme.engraveDim)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(width: 44)
    }
}

/// Coarse category for the current output, derived from the device name
/// (SherlockEQ exposes only the name). The real device name is shown
/// verbatim alongside, so this never hides which device is selected.
enum OutputCategory: CaseIterable, Identifiable {
    case builtIn, external, headphones, bluetooth, other

    var id: Self { self }

    var label: String {
        switch self {
        case .builtIn:    return "BUILT-IN"
        case .external:   return "EXTERNAL"
        case .headphones: return "HEADPHONES"
        case .bluetooth:  return "BLUETOOTH"
        case .other:      return "OTHER"
        }
    }

    var spoken: String {
        switch self {
        case .builtIn:    return "Built-in speakers"
        case .external:   return "External speakers"
        case .headphones: return "Headphones"
        case .bluetooth:  return "Bluetooth"
        case .other:      return "Other output"
        }
    }

    init(deviceName: String) {
        let n = deviceName.lowercased()
        if n.contains("airpod") || n.contains("bluetooth") || n.contains("beats") {
            self = .bluetooth
        } else if n.contains("headphone") || n.contains("earphone") {
            self = .headphones
        } else if n.contains("macbook") || n.contains("built-in") || n.contains("internal") || n.contains("imac") || n.contains("mac mini") || n.contains("mac studio") {
            self = .builtIn
        } else if n.contains("display") || n.contains("monitor") || n.contains("usb") || n.contains("hdmi") || n.contains("dac") || n.contains("external") || n.contains("speaker") {
            self = .external
        } else {
            self = .other
        }
    }
}

// MARK: - Faceplate chrome

/// Dark brushed-metal faceplate: charcoal gradient + fine horizontal
/// grain, a top sheen, and a soft vignette. The chassis bevel is provided
/// by the window; this fills it edge to edge.
private struct AnalogFaceplate: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AnalogTheme.faceTop, AnalogTheme.faceBottom],
                startPoint: .top, endPoint: .bottom
            )
            Canvas { ctx, size in
                var y: CGFloat = 0
                while y < size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(path, with: .color(.white.opacity(0.012)), lineWidth: 0.5)
                    y += 2
                }
            }
            LinearGradient(
                colors: [Color.white.opacity(0.05), .clear],
                startPoint: .top, endPoint: .center
            )
            RadialGradient(
                colors: [.clear, Color.black.opacity(0.35)],
                center: .center, startRadius: 180, endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Recessed inset panel

private extension View {
    /// Make content look set *into* the faceplate: dark well, dark hairline
    /// border, a soft inner top shadow, and a faint light bottom lip.
    func recessed() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(AnalogTheme.recess)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color.black.opacity(0.7), lineWidth: 4)
                            .blur(radius: 3)
                            .mask(RoundedRectangle(cornerRadius: 9))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.black.opacity(0.7), Color.white.opacity(0.06)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
    }
}
