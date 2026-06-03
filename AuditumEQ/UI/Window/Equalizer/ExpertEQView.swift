import SwiftUI

/// Parametric EQ surface: full-control biquad editing per ear.
/// Drag nodes on the canvas, tune the selected band's Q / filter type /
/// gain / freq below, or add/remove bands from the toolbar.
struct ExpertEQView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var audioState: AudioState

    private enum EarTab: String, CaseIterable, Hashable {
        case left = "Left ear"
        case right = "Right ear"
    }
    @State private var tab: EarTab = .left
    @State private var selectedBandID: UUID?
    /// Display preference for the Q/BW readout — Q value vs equivalent
    /// bandwidth in octaves. Storage is always Q internally.
    @State private var showQAsOctaves: Bool = false

    var body: some View {
        if let profile = audioState.activeProfile(in: profileStore) {
            content(profile)
        } else {
            ContentUnavailableView(
                "No active profile",
                systemImage: "slider.horizontal.3",
                description: Text("Make a profile active to edit its EQ.")
            )
        }
    }

    @FocusState private var canvasFocused: Bool

    @ViewBuilder private func content(_ profile: HearingProfile) -> some View {
        VStack(spacing: 14) {
            header
            ParametricCanvasView(
                bands: bandsBinding(for: profile),
                shadowBands: shadowBands(for: profile),
                notch: profile.notch,
                spectrumBinsDB: audioState.spectrum.logSpectrumDB,
                spectrumPeakHoldDB: audioState.spectrum.logSpectrumPeakHoldDB,
                preSpectrumBinsDB: audioState.preSpectrum.logSpectrumDB,
                spectrumSampleRate: audioState.audio.outputSampleRate ?? 48_000,
                earColor: earColor,
                shadowColor: shadowColor,
                selectedBandID: $selectedBandID
            )
            .frame(minHeight: 280)
            .focusable()
            .focused($canvasFocused)
            .onKeyPress { press in handleKey(press, in: profile) }
            .onTapGesture { canvasFocused = true }
            controlsBar(profile)
            NotchControlView(notch: notchBinding(for: profile))
        }
        .padding(20)
    }

    /// Map keys to selected-band edits (spec §5.9 power-user goal). Each
    /// edit reads the band fresh because the binding's captured profile may
    /// be stale after the previous edit's save.
    private func handleKey(_ press: KeyPress, in profile: HearingProfile) -> KeyPress.Result {
        guard let id = selectedBandID,
              let band = activeBands(in: profile).first(where: { $0.id == id }) else {
            return .ignored
        }

        let stepGain: Double = press.modifiers.contains(.shift) ? 0.5 : 1.0
        let bigGain: Double = 5.0
        // ±5 % per arrow, ±15 % with shift, ±50 % with command.
        let freqStep: Double = press.modifiers.contains(.shift) ? 1.15 : 1.05
        let freqBigStep: Double = 1.5

        switch press.key {
        case .upArrow:
            let amount = press.modifiers.contains(.command) ? bigGain : stepGain
            update(band: band) { $0.gaindB = clampDB($0.gaindB + amount) }
            return .handled
        case .downArrow:
            let amount = press.modifiers.contains(.command) ? bigGain : stepGain
            update(band: band) { $0.gaindB = clampDB($0.gaindB - amount) }
            return .handled
        case .leftArrow:
            let factor = press.modifiers.contains(.command) ? freqBigStep : freqStep
            update(band: band) { $0.frequencyHz = clampHz($0.frequencyHz / factor) }
            return .handled
        case .rightArrow:
            let factor = press.modifiers.contains(.command) ? freqBigStep : freqStep
            update(band: band) { $0.frequencyHz = clampHz($0.frequencyHz * factor) }
            return .handled
        case .delete, .deleteForward:
            removeBand(band)
            return .handled
        case .space:
            update(band: band) { $0.enabled.toggle() }
            return .handled
        case .return:
            update(band: band) { $0.gaindB = 0 }
            return .handled
        default:
            // "[" and "]" tighten/widen Q
            if press.characters == "[" {
                update(band: band) { $0.bandwidth = max(0.1, $0.bandwidth - 0.1) }
                return .handled
            }
            if press.characters == "]" {
                update(band: band) { $0.bandwidth = min(10, $0.bandwidth + 0.1) }
                return .handled
            }
            return .ignored
        }
    }

    private func activeBands(in profile: HearingProfile) -> [EQBand] {
        tab == .left ? profile.leftEar.bands : profile.rightEar.bands
    }

    private func notchBinding(for profile: HearingProfile) -> Binding<TinnitusNotch> {
        Binding(
            get: { profile.notch },
            set: { newValue in
                var updated = profile
                updated.notch = newValue
                try? profileStore.save(updated)
            }
        )
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(EarTab.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)

            Spacer()

            Label("\(activeBands.count) band\(activeBands.count == 1 ? "" : "s")",
                  systemImage: "rectangle.stack")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("", selection: $showQAsOctaves) {
                Text("Q").tag(false)
                Text("Oct").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 80)
            .help("Display the selected band's width as Q or as octave bandwidth")

            Button {
                addBand()
            } label: {
                Label("Add band", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func controlsBar(_ profile: HearingProfile) -> some View {
        if let id = selectedBandID, let band = activeBands.first(where: { $0.id == id }) {
            HStack(spacing: 14) {
                Toggle("On", isOn: enabledBinding(for: band))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .frame(width: 70, alignment: .leading)

                Menu {
                    ForEach(EQFilterType.allCases, id: \.self) { type in
                        Button(filterTypeLabel(type)) { setType(for: band, to: type) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.below.rectangle")
                        Text(filterTypeLabel(band.filterType))
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 150, alignment: .leading)

                paramRow("Freq", value: Int(band.frequencyHz), unit: "Hz") { dragged in
                    update(band: band) { $0.frequencyHz = clampHz($0.frequencyHz + Double(dragged) * 5) }
                }

                paramRow("Gain", value: Int(band.gaindB), unit: "dB") { dragged in
                    update(band: band) { $0.gaindB = clampDB($0.gaindB + Double(dragged) * 0.1) }
                }

                let widthLabel = showQAsOctaves ? "BW" : "Q"
                let widthDisplay: String = showQAsOctaves
                    ? String(format: "%.2f oct", Self.octavesFromQ(band.bandwidth))
                    : String(format: "%.2f", band.bandwidth)
                paramRow(widthLabel, value: widthDisplay, unit: nil) { dragged in
                    update(band: band) {
                        $0.bandwidth = max(0.1, min(10, $0.bandwidth + Double(dragged) * 0.02))
                    }
                }

                Spacer()

                Button(role: .destructive) {
                    removeBand(band)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove selected band")
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))
            )
        } else {
            HStack {
                Image(systemName: "hand.point.up.left.fill").foregroundStyle(.secondary)
                Text("Drag a node on the curve to edit it, or **Add band** above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.06))
            )
        }
    }

    private func paramRow<V>(
        _ label: String,
        value: V,
        unit: String?,
        onDelta: @escaping (Float) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text("\(String(describing: value))")
                    .font(.callout.monospaced())
                if let unit { Text(unit).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .frame(width: 70, alignment: .leading)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    onDelta(Float(value.translation.height) * -1)
                }
        )
    }

    // MARK: - Helpers

    private var activeProfile: HearingProfile? {
        audioState.activeProfile(in: profileStore)
    }

    private var activeBands: [EQBand] {
        guard let profile = activeProfile else { return [] }
        return tab == .left ? profile.leftEar.bands : profile.rightEar.bands
    }

    private var earColor: Color { tab == .left ? .blue : .red }
    private var shadowColor: Color { tab == .left ? .red : .blue }

    private func shadowBands(for profile: HearingProfile) -> [EQBand] {
        tab == .left ? profile.rightEar.bands : profile.leftEar.bands
    }

    private func bandsBinding(for profile: HearingProfile) -> Binding<[EQBand]> {
        Binding(
            get: { tab == .left ? profile.leftEar.bands : profile.rightEar.bands },
            set: { newBands in
                var updated = profile
                if tab == .left { updated.leftEar.bands = newBands }
                else { updated.rightEar.bands = newBands }
                try? profileStore.save(updated)
            }
        )
    }

    private func enabledBinding(for band: EQBand) -> Binding<Bool> {
        Binding(
            get: { band.enabled },
            set: { newValue in update(band: band) { $0.enabled = newValue } }
        )
    }

    private func update(band: EQBand, _ mutate: (inout EQBand) -> Void) {
        guard var profile = activeProfile else { return }
        var bands = tab == .left ? profile.leftEar.bands : profile.rightEar.bands
        guard let idx = bands.firstIndex(where: { $0.id == band.id }) else { return }
        mutate(&bands[idx])
        if tab == .left { profile.leftEar.bands = bands } else { profile.rightEar.bands = bands }
        try? profileStore.save(profile)
    }

    private func setType(for band: EQBand, to type: EQFilterType) {
        update(band: band) { $0.filterType = type }
    }

    private func addBand() {
        guard var profile = activeProfile else { return }
        let new = EQBand(
            frequencyHz: 1000,
            gaindB: 0,
            bandwidth: 1.0,
            filterType: .parametric,
            enabled: true
        )
        if tab == .left { profile.leftEar.bands.append(new) }
        else { profile.rightEar.bands.append(new) }
        try? profileStore.save(profile)
        selectedBandID = new.id
    }

    private func removeBand(_ band: EQBand) {
        guard var profile = activeProfile else { return }
        if tab == .left { profile.leftEar.bands.removeAll { $0.id == band.id } }
        else { profile.rightEar.bands.removeAll { $0.id == band.id } }
        try? profileStore.save(profile)
        selectedBandID = nil
    }

    private func filterTypeLabel(_ t: EQFilterType) -> String {
        switch t {
        case .parametric: return "Parametric"
        case .lowShelf:   return "Low shelf"
        case .highShelf:  return "High shelf"
        case .notch:      return "Notch"
        case .bandPass:   return "Band-pass"
        case .lowPass:    return "Low-pass"
        case .highPass:   return "High-pass"
        }
    }

    private func clampHz(_ v: Double) -> Double { max(20, min(20_000, v)) }
    private func clampDB(_ v: Double) -> Double { max(-24, min(24, v)) }

    /// Q → equivalent bandwidth in octaves (Audio EQ Cookbook formula).
    static func octavesFromQ(_ q: Double) -> Double {
        guard q > 0 else { return 0 }
        return (2.0 / log(2.0)) * asinh(1.0 / (2.0 * q))
    }
}
