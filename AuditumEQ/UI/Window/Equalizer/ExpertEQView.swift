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

    @ViewBuilder private func content(_ profile: HearingProfile) -> some View {
        VStack(spacing: 14) {
            header
            ParametricCanvasView(
                bands: bandsBinding(for: profile),
                shadowBands: shadowBands(for: profile),
                notch: profile.notch,
                spectrumBinsDB: audioState.spectrum.spectrumBinsDB,
                spectrumPeakHoldDB: audioState.spectrum.spectrumPeakHoldDB,
                spectrumSampleRate: audioState.audio.outputSampleRate ?? 48_000,
                earColor: earColor,
                shadowColor: shadowColor,
                selectedBandID: $selectedBandID
            )
            controlsBar(profile)
            NotchControlView(notch: notchBinding(for: profile))
        }
        .padding(20)
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

                paramRow("Q", value: String(format: "%.2f", band.bandwidth), unit: nil) { dragged in
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
        case .lowPass:    return "Low-pass"
        case .highPass:   return "High-pass"
        }
    }

    private func clampHz(_ v: Double) -> Double { max(20, min(20_000, v)) }
    private func clampDB(_ v: Double) -> Double { max(-24, min(24, v)) }
}
