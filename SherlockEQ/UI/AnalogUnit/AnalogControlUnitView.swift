import SwiftUI

/// The Analog Control Unit — an optional, playful "front panel" for five
/// adjustments people understand immediately: Volume, Balance, Bass, Mid,
/// Treble.
///
///   • Volume → macOS system output volume (`SystemVolumeController`).
///   • Balance + Bass/Mid/Treble → a dedicated, hidden "analog" override
///     profile (`AudioState.analogOverrideProfile`): a bare three-band tone
///     with no audiogram / notch / clarity / AutoEQ. Opening the window
///     routes audio through it; closing restores the real active profile,
///     which is never touched. The tone persists across opens.
///   • VU meters → the shared `AnalogVUMeter` + `StereoMonitor`.
///   • Output → read-only indicator of the current system output.
struct AnalogControlUnitView: View {
    @EnvironmentObject private var audioState: AudioState
    /// The one knob that reaches outside SherlockEQ: VOLUME drives the macOS
    /// system output level, not the app's internal gain.
    @StateObject private var systemVolume = SystemVolumeController()
    /// OUTPUT selector — enumerates output devices and switches the macOS
    /// default output (the tap follows it). Like VOLUME, this reaches outside
    /// SherlockEQ: it reroutes all system audio, not just the app.
    @StateObject private var systemOutput = SystemOutputDeviceController()

    // Spectrum-analyzer panel state (persisted, view-only display settings).
    @AppStorage(AnalogSpectrumConfig.expandedKey) private var spectrumExpanded = false
    @AppStorage("sherlockeq.analogControlUnit.spectrumColorful") private var spectrumColorful = true
    @AppStorage("sherlockeq.analogControlUnit.spectrumDimmer") private var spectrumDimmer = 0.85
    @AppStorage("sherlockeq.analogControlUnit.spectrumSensitivity") private var spectrumSensitivity = 0.0
    @AppStorage("sherlockeq.analogControlUnit.spectrumPeakOnly") private var spectrumPeakOnly = false

    /// The analog override is present while the window is open (set by
    /// `AppDelegate.showAnalogControlUnit`), so the tone knobs are live.
    private var hasOverride: Bool {
        audioState.analogOverrideProfile != nil
    }

    var body: some View {
        ZStack {
            AnalogFaceplate()
            VStack(spacing: 12) {
                header
                HStack(alignment: .center, spacing: 12) {
                    AnalogVUMeter(
                        monitor: audioState.stereoMonitor,
                        mode: .stereo,
                        calibration: .standardDigital(),
                        showReadout: false
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 152)
                    .padding(8)
                    .recessed()

                    volumeColumn
                }

                knobRow
                if spectrumExpanded {
                    spectrumPanel
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 14)
        }
        // Contextual help — the panel maps onto existing controls, so the
        // `?` explains that mapping (Volume→system volume, Bass/Mid/Treble→tone bands).
        .overlay(alignment: .topTrailing) {
            HelpContextButton(.analogControlUnit, label: "Analog Control Unit")
                .padding(10)
        }
        .overlay(alignment: .bottomTrailing) {
            disclosureButton
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
        }
        .frame(minWidth: 700, idealWidth: 700,
               minHeight: AnalogSpectrumConfig.collapsedHeight, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .onAppear {
            audioState.stereoMonitor.subscribe()
            systemVolume.start()
            systemOutput.start()
        }
        .onDisappear {
            audioState.stereoMonitor.unsubscribe()
            systemVolume.stop()
            systemOutput.stop()
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
                size: 116,
                resettable: false
            )
            .disabled(!systemVolume.isAvailable)
            Text(systemVolume.isAvailable ? "SYSTEM" : "NO CONTROL")
                .font(.system(size: 8, weight: .semibold))
                .tracking(2)
                .foregroundStyle(AnalogTheme.engraveDim)
        }
        .frame(width: 150)
    }

    // MARK: Spectrum analyzer (expandable)

    private var spectrumPanel: some View {
        HStack(alignment: .center, spacing: 12) {
            AnalogSpectrumBars(
                spectrum: audioState.spectrum,
                colorful: spectrumColorful,
                dimmer: spectrumDimmer,
                sensitivityDB: spectrumSensitivity,
                peakOnly: spectrumPeakOnly
            )
            .frame(maxWidth: .infinity)
            .frame(height: 152)
            .padding(8)
            .recessed()

            spectrumControls
        }
        .frame(height: 176)
    }

    private var spectrumControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                AnalogKnob(
                    title: "DIMMER", value: $spectrumDimmer,
                    range: 0.2...1.0, defaultValue: 0.85, step: 0.05,
                    formatter: Self.percentLabel, accessibilityValue: Self.percentSpoken,
                    size: 46
                )
                AnalogKnob(
                    title: "SENS", value: $spectrumSensitivity,
                    range: -12...24, defaultValue: 0, step: 1, detentValue: 0,
                    formatter: Self.dbLabel, accessibilityValue: Self.dbSpoken,
                    size: 46
                )
            }
            HStack(spacing: 14) {
                AnalogToggleButton(
                    isOn: $spectrumColorful,
                    label: "COLOR",
                    accessibilityName: "Colourful bars"
                )
                AnalogToggleButton(
                    isOn: $spectrumPeakOnly,
                    label: "PEAK",
                    accessibilityName: "Peak-tick mode"
                )
            }
        }
        .frame(width: 150)
    }

    private var disclosureButton: some View {
        Button { toggleExpanded() } label: {
            Image(systemName: spectrumExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AnalogTheme.engraveDim)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(spectrumExpanded ? "Hide spectrum analyzer" : "Show spectrum analyzer")
        .accessibilityLabel("Spectrum analyzer")
        .accessibilityValue(spectrumExpanded ? "shown" : "hidden")
    }

    private func toggleExpanded() {
        if spectrumExpanded {
            // Collapse: fade the spectrum out first, then slide the window up
            // to close the gap it leaves.
            withAnimation(.easeInOut(duration: 0.18)) { spectrumExpanded = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                // Guard against a rapid re-expand during the fade: only shrink
                // if we're *still* collapsed when this fires. Otherwise this
                // stale shrink would fight the expand path that already grew
                // the window, leaving height and chevron out of sync.
                guard !spectrumExpanded else { return }
                AppDelegate.shared?.setAnalogControlUnitExpanded(false)
            }
        } else {
            // Expand: add the panel, then grow the window to reveal it as it
            // slides into view (open already felt smooth — keep it snappy).
            spectrumExpanded = true
            AppDelegate.shared?.setAnalogControlUnitExpanded(true)
        }
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
            .disabled(!hasOverride)
            hairline
            AnalogKnob(
                title: "BASS",
                value: eqBinding(frequencyHz: 250, bandwidth: 0.707, filterType: .lowShelf),
                range: -12...12, defaultValue: 0, step: 0.5, detentValue: 0,
                formatter: Self.dbLabel, accessibilityValue: Self.dbSpoken
            )
            .disabled(!hasOverride)
            AnalogKnob(
                title: "MID",
                value: eqBinding(frequencyHz: 1000, bandwidth: 1.8, filterType: .parametric),
                range: -12...12, defaultValue: 0, step: 0.5, detentValue: 0,
                formatter: Self.dbLabel, accessibilityValue: Self.dbSpoken
            )
            .disabled(!hasOverride)
            AnalogKnob(
                title: "TREBLE",
                value: eqBinding(frequencyHz: 5000, bandwidth: 0.707, filterType: .highShelf),
                range: -12...12, defaultValue: 0, step: 0.5, detentValue: 0,
                formatter: Self.dbLabel, accessibilityValue: Self.dbSpoken
            )
            .disabled(!hasOverride)
            hairline
            AnalogOutputSelector(controller: systemOutput)
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
            get: { audioState.analogOverrideProfile?.balance ?? 0 },
            set: { newValue in
                audioState.updateAnalogOverride { $0.balance = newValue }
            }
        )
    }

    /// Edits one tone shelf/parametric band on the Analog Unit's own
    /// override profile (never the user's active profile). Mono tone —
    /// writes both ears in lockstep; reads the left ear as representative.
    private func eqBinding(frequencyHz: Double, bandwidth: Double, filterType: EQFilterType) -> Binding<Double> {
        Binding(
            get: {
                guard let p = audioState.analogOverrideProfile else { return 0 }
                return EQBandLookup.gain(at: frequencyHz, filterType: filterType, in: p.leftEar.bands)
            },
            set: { newValue in
                audioState.updateAnalogOverride { p in
                    EQBandLookup.mutateBothEars(of: &p) { bands in
                        EQBandLookup.setGain(newValue, at: frequencyHz, bandwidth: bandwidth, filterType: filterType, in: &bands)
                    }
                }
            }
        )
    }

    // MARK: - Label formatters
    //
    // `nonisolated`: pure string math handed to AnalogKnob as callbacks that
    // may run outside the main actor (audit BLD-02).

    nonisolated static func percentLabel(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }

    nonisolated static func percentSpoken(_ v: Double) -> String {
        "\(Int((v * 100).rounded())) percent"
    }

    nonisolated static func dbLabel(_ v: Double) -> String {
        if abs(v) < 0.05 { return "0 dB" }
        return String(format: "%@%.1f dB", v > 0 ? "+" : "\u{2212}", abs(v))
    }

    nonisolated static func dbSpoken(_ v: Double) -> String {
        if abs(v) < 0.05 { return "0 decibels" }
        return String(format: "%@ %.1f decibels", v > 0 ? "plus" : "minus", abs(v))
    }

    nonisolated static func balanceLabel(_ v: Double) -> String {
        if abs(v) < 0.005 { return "C" }
        let pct = Int((abs(v) * 100).rounded())
        return v < 0 ? "L \(pct)" : "R \(pct)"
    }

    nonisolated static func balanceSpoken(_ v: Double) -> String {
        if abs(v) < 0.005 { return "centered" }
        let pct = Int((abs(v) * 100).rounded())
        return v < 0 ? "\(pct) percent left" : "\(pct) percent right"
    }
}

// MARK: - Output selector (switches the system default output)

/// "OUTPUT" strip: one push button per available output device. The lit
/// (depressed, amber-lamped) button is the current system default; pressing
/// another makes *it* the system default — SherlockEQ's tap follows the
/// default output and rebuilds onto it. The actual device name shows below.
///
/// This reroutes all system audio, exactly like the menu-bar Sound control:
/// SherlockEQ taps whatever the default output is, so switching the default
/// is the only honest way to change speakers from the panel.
struct AnalogOutputSelector: View {
    @ObservedObject var controller: SystemOutputDeviceController

    private var activeName: String {
        controller.devices.first(where: { $0.id == controller.currentDeviceID })?.name ?? "—"
    }

    var body: some View {
        VStack(spacing: 5) {
            Text("OUTPUT")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(AnalogTheme.engrave)

            HStack(spacing: 14) {
                ForEach(controller.devices) { device in
                    AnalogOutputButton(
                        device: device,
                        isActive: device.id == controller.currentDeviceID,
                        action: { controller.select(device) }
                    )
                }
            }

            Text(activeName)
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .foregroundStyle(AnalogTheme.engraveDim)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 200)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Output device"))
    }
}

/// A vintage metal push button for one output device: a vertical pill with the
/// device's category icon *underneath* it. The active (default) device reads
/// as engaged — depressed pill + lit amber lamp, amber icon; the others sit
/// raised with a dim icon. Pressing makes this device the system default.
private struct AnalogOutputButton: View {
    let device: CATapEngine.OutputDevice
    let isActive: Bool
    let action: () -> Void

    private var icon: String { OutputCategory(deviceName: device.name).icon }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                AnalogPillCap(isActive: isActive)
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isActive ? AnalogTheme.amber : AnalogTheme.engraveDim)
                    .shadow(color: isActive ? AnalogTheme.amber.opacity(0.7) : .clear, radius: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isActive ? "\(device.name) (current output)" : "Switch output to \(device.name)")
        .accessibilityLabel(Text(device.name))
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

/// Coarse category for an output device, derived from its name — picks the SF
/// Symbol shown under each OUTPUT button. The real device name is shown
/// verbatim alongside, so this never hides which device is selected.
enum OutputCategory {
    case builtIn, external, headphones, bluetooth, other

    /// SF Symbol shown on the push button. The device name (below the row)
    /// carries the precise identity; this icon just hints at the kind.
    var icon: String {
        switch self {
        case .builtIn:    return "laptopcomputer"
        case .external:   return "hifispeaker.fill"
        case .headphones: return "headphones"
        case .bluetooth:  return "wave.3.right"
        case .other:      return "speaker.wave.2.fill"
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
