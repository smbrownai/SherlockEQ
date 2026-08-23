import SwiftUI
import Combine

/// Right-hand monitoring panel — a slide-in trailing column opened on demand
/// from the toolbar's `MonitorToggleButton` (it used to be a persistent
/// gutter, but its usual state was an idle low-information repeat, so it's
/// collapsed by default now). Its visibility flag `monitorSidebarVisible`
/// persists in @AppStorage. Each control here carries an explicit scope
/// label so it's unambiguous whether a value is app-wide or per-profile.
///
/// Contents (top → bottom):
///   1. Output level VU — vertical L/R peak meter. Triple-tap the
///      header to swap between the Digital and Analog VU display modes
///      (the analog dial is the nostalgic easter egg shared with the
///      Analog Control Unit).
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
        case digital, analog

        var label: String {
            switch self {
            case .digital: return "Output level"
            case .analog:  return "Analog VU"
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
            HStack(spacing: 4) {
                Text(displayMode.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 3) { displayMode = displayMode.next }
                    .help("Triple-tap to cycle display modes.")
                Spacer()
                HelpContextButton(.vuMeters, label: "VU meters and visualization")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            switch displayMode {
            case .digital:
                DigitalLRMeter(
                    monitor: audioState.stereoMonitor,
                    // Effective (volume-tracked) offset — see volume-aware-dose.md.
                    calibrationOffsetDBA: audioState.effectiveCalibrationOffsetDBA
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
                    calibration: audioState.analogVUCalibration,
                    vertical: true
                )
                .frame(height: 240)
            }
        }
    }

    // MARK: - Volume

    @ViewBuilder private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // Scope badge (App) marks this as the app-wide output gain,
                // the same value the popover and Settings expose — not a
                // per-profile setting.
                Text("Master gain")
                    .font(.caption.weight(.semibold))
                ScopeBadge(scope: .app)
                Spacer()
                Text(formatGain(audioState.engineParameters.masterGainDB))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { audioState.engineParameters.masterGainDB },
                        set: { audioState.engineParameters.masterGainDB = $0 }
                    ),
                    in: -60...12
                )
                .accessibilityLabel("Master gain")
                .controlSize(.small)
                Button {
                    audioState.engineParameters.masterGainDB = 0
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
                HStack(spacing: 6) {
                    // Scope badge (Profile): balance is saved with the active
                    // profile (editing here is the same as ProfileDetail's
                    // balance row) — unlike the app-wide gain above it.
                    Text("Balance")
                        .font(.caption.weight(.semibold))
                    ScopeBadge(scope: .profile)
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
                                // Live copy, not the body-render snapshot —
                                // saving the stale struct clobbers concurrent
                                // edits from other surfaces (audit CX-05).
                                var updated = profileStore.profiles.first { $0.id == profile.id } ?? profile
                                updated.balance = newValue
                                try? profileStore.save(updated)
                            }
                        ),
                        in: -1...1
                    )
                    .controlSize(.small)
                    .accessibilityLabel("Balance")
                    Button {
                        var updated = profileStore.profiles.first { $0.id == profile.id } ?? profile
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
        // "Centered" (not "Center") to match the toolbar status glance
        // that summarizes this panel.
        if abs(b) < 0.005 { return "Centered" }
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
        MonitorDoseCard(tracker: audioState.safeListening)
    }
}

/// The dose mini-bar as its own observation scope: it reads the tracker
/// directly on a 1 Hz throttled tick (the PopoverLiveStatusRows pattern)
/// instead of riding a mirrored @Published on AudioState — that mirror
/// re-rendered every @EnvironmentObject view tree once a second during
/// playback (perf review S1).
private struct MonitorDoseCard: View {
    let tracker: SafeListeningTracker

    /// Bumped by the throttled subscription; `body` reads it so each tick
    /// invalidates this card — and only this card.
    @State private var tick = 0

    var body: some View {
        let _ = tick   // tick dependency — see property comment
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // Scope badge (Today): cumulative exposure for today (resets
                // at local midnight), not a live level — the VU above is the
                // live signal.
                Text("Exposure")
                    .font(.caption.weight(.semibold))
                ScopeBadge(scope: .session)
                Spacer()
                Image(systemName: doseZoneSymbol)
                    .foregroundStyle(doseColor)
                    .font(.caption.weight(.semibold))
                Text(String(format: "%.0f %%", tracker.displayDose * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(doseColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(doseColor)
                        .frame(width: max(2, geo.size.width * tracker.displayDose))
                }
            }
            .frame(height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today's exposure")
        .accessibilityValue(doseAccessibilityValue)
        .onReceive(tracker.objectWillChange
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)) { _ in
            tick &+= 1
        }
    }

    private var doseColor: Color {
        switch tracker.doseSeverity {
        case .safe:  return .green
        case .amber: return .orange
        case .red:   return .red
        }
    }

    /// Non-color redundant encoding paired with `doseColor` so the
    /// severity reads for colorblind users without relying on tint.
    private var doseZoneSymbol: String {
        switch tracker.doseSeverity {
        case .safe:  return "checkmark.shield.fill"
        case .amber: return "exclamationmark.triangle.fill"
        case .red:   return "exclamationmark.octagon.fill"
        }
    }

    private var doseAccessibilityValue: String {
        let percent = Int(tracker.displayDose * 100)
        let zone: String = {
            switch tracker.doseSeverity {
            case .safe:  return "safe"
            case .amber: return "approaching limit"
            case .red:   return "at or past limit"
            }
        }()
        return "\(percent)%, \(zone)"
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
            // Static: the dBFS reference scale never moves, so it is its own
            // view and gets skipped on every meter tick. See `MeterScaleColumn`.
            MeterScaleColumn()
                .equatable()
            // A11y strings passed as literals rather than interpolated per
            // render — see `a11yValue` for why this matters at 60 Hz.
            channelColumn(label: "L", a11yLabel: "L channel peak level", peak: monitor.leftPeak)
            channelColumn(label: "R", a11yLabel: "R channel peak level", peak: monitor.rightPeak)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func channelColumn(label: String, a11yLabel: String, peak: Float) -> some View {
        VStack(spacing: 5) {
            Text(label)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(.secondary)
            meterBar(peak: peak)
                .frame(width: 18)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
        .accessibilityValue(Self.a11yValue(peak: peak, calibrationOffsetDBA: calibrationOffsetDBA))
    }

    /// Peak readout for assistive technologies, built WITHOUT `String(format:)`.
    ///
    /// This line and the label above it were the two hottest app frames in a
    /// Release-build sampler run — `MonitorSidebar.swift:336` and `:337`. The
    /// meter re-renders on every 60 Hz `StereoMonitor` tick, so each channel
    /// was paying CVarArg boxing plus NSString format parsing 120 times a
    /// second between them. Interpolating an already-rounded `Int` produces
    /// the same string far more cheaply.
    ///
    /// The value is still built unconditionally rather than gated on
    /// `accessibilityVoiceOverEnabled`: VoiceOver is not the only client
    /// (Accessibility Inspector, Switch Control and friends read it too), and
    /// a meter that reports nothing to those is a worse bug than a warm CPU.
    private static func a11yValue(peak: Float, calibrationOffsetDBA: Double) -> String {
        let peakDB = peak > 1e-5 ? 20 * log10(Double(peak)) : -60.0
        let zone: String
        if peakDB >= 85 - calibrationOffsetDBA {
            zone = "very loud"
        } else if peakDB >= 70 - calibrationOffsetDBA {
            zone = "loud"
        } else {
            zone = "moderate"
        }
        return "\(Int(peakDB.rounded())) dBFS, \(zone)"
    }

    /// Map a dBFS value to a y-coordinate within a bar of the given
    /// height. 0 dB sits at the top (y = 0), -60 dB at the bottom
    /// (y = height). Bigger dB → smaller y.
    ///
    /// `fileprivate` rather than `private` so the extracted
    /// `MeterScaleColumn` shares this mapping instead of restating it —
    /// the tick labels must land on the same scale as the bar fill.
    fileprivate static func y(forDB dB: Double, height: CGFloat) -> CGFloat {
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

                // Zone-boundary tick marks. Non-color redundant
                // encoding so colorblind users can locate the
                // moderate / loud / very-loud thresholds without
                // relying on the green / yellow / red transitions.
                // LevelMeterView already draws equivalent ticks.
                Rectangle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(height: 1)
                    .offset(y: yYellow)
                Rectangle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(height: 1)
                    .offset(y: yRed)
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

/// The dBFS reference scale alongside the L/R bars. Calibration-independent —
/// these reference points sit at the same dBFS positions regardless of the
/// user's calibration slider, so the visual position of each tick label
/// corresponds directly to the bar's fill height for that dBFS level. The
/// zone-boundary colours (yellow / red) shift with calibration; this scale
/// doesn't.
///
/// It is a separate view precisely *because* nothing about it changes. It used
/// to be a computed property on `DigitalLRMeter`, which meant its
/// `GeometryReader` and four monospaced-digit `Text` labels were rebuilt on
/// every 60 Hz `StereoMonitor` tick along with the bars. Holding no stored
/// state, it compares equal to itself, so SwiftUI skips it and the ticks are
/// laid out once — same idiom as `CanvasChromeLayer` on the EQ canvas.
struct MeterScaleColumn: View, Equatable {
    var body: some View {
        VStack(spacing: 5) {
            Text("dB")
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ForEach(Self.scaleTicks, id: \.self) { db in
                    let rawY = DigitalLRMeter.y(forDB: db, height: geo.size.height)
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
}
