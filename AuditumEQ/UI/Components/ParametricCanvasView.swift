import SwiftUI

/// Underlay mode for the parametric canvas. `.spectrum` keeps the
/// existing line+peak-hold + pre-EQ outline. `.spectrogram` swaps in a
/// rolling time × frequency heatmap. `.octaveBars` collapses the
/// spectrum into 31 ISO 1/3-octave bars.
enum CanvasVizMode: String, CaseIterable, Identifiable {
    case spectrum
    case spectrogram
    case octaveBars

    var id: String { rawValue }
    var label: String {
        switch self {
        case .spectrum:    return "Spectrum"
        case .spectrogram: return "Spectrogram"
        case .octaveBars:  return "Bars"
        }
    }
}

/// Interactive frequency-response canvas for a per-ear EQ chain.
///
/// Vertical axis: ±24 dB. Horizontal axis: log frequency from 20 Hz to 20 kHz.
/// Draws the composite biquad curve from `bands`, the optional `shadowBands`
/// for the *other* ear (rendered as a thin trace for comparison), and the
/// spectrum analyzer underlay at the bottom 1/3.
///
/// Interaction: drag any band's node to edit `frequencyHz` (x) and `gaindB`
/// (y). Selecting a node updates `selectedBandID` so the parent can show
/// detail controls (Q, type, enable) for that band.
struct ParametricCanvasView: View {
    @Binding var bands: [EQBand]
    var shadowBands: [EQBand] = []
    /// Optional tinnitus notch (spec §5.3). Rendered as an extra band on the
    /// composite curve when `enabled`. Not draggable from the canvas — edits
    /// happen via `NotchControlView` so the dedicated frequency/depth/width
    /// inputs stay authoritative.
    var notch: TinnitusNotch? = nil
    /// Pre-smoothed log-binned spectrum from `SpectrumAnalyzer.logSpectrumDB`.
    /// Linear-bin FFT data (`spectrumBinsDB`) is no longer drawn — the log
    /// version is uniform across the visible frequency range.
    var spectrumBinsDB: [Float] = []
    var spectrumPeakHoldDB: [Float] = []
    /// Optional pre-EQ spectrum (log-binned) drawn as a thin cyan outline so
    /// the user can see what's coming in vs what's leaving the chain.
    var preSpectrumBinsDB: [Float] = []
    /// Rolling history of past `spectrumBinsDB` frames — only consumed in
    /// `.spectrogram` mode. Oldest frame at index 0, newest at end.
    var spectrumHistory: [[Float]] = []
    var spectrumSampleRate: Double = 48_000
    var earColor: Color = .blue
    var shadowColor: Color = .red
    /// Which underlay visualisation to render. Editors that want a static
    /// preview default to `.spectrum`; the Expert canvas drives this from
    /// a segmented control persisted in `@AppStorage`.
    var vizMode: CanvasVizMode = .spectrum
    /// When true, the canvas is a passive visualisation — no drag handles,
    /// no node markers, no selection. Used by Simple/Advanced tabs to give
    /// an at-a-glance preview of the current curve while the user moves
    /// sliders below.
    var readOnly: Bool = false
    @Binding var selectedBandID: UUID?

    private let minHz: Double = 20
    private let maxHz: Double = 20_000
    private let minDB: Double = -24
    private let maxDB: Double = 24
    private let nodeRadius: CGFloat = 8
    private let nodeHitRadius: CGFloat = 16

    /// Spectrum vertical mapping (dBFS). Per spec §5.9 the analyzer sits
    /// underneath the EQ curve in a constrained band, not over the full
    /// canvas — `spectrumHeightFraction` is how much of the canvas it gets.
    private let spectrumMinDB: Double = -90
    private let spectrumMaxDB: Double = -20
    private let spectrumHeightFraction: CGFloat = 0.4

    @State private var dragState: DragState?

    private struct DragState {
        let bandID: UUID
        let startBand: EQBand
        let canvasSize: CGSize
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Canvas { context, size in
                    switch vizMode {
                    case .spectrum:
                        drawSpectrum(context, size: size)
                        drawPreSpectrum(context, size: size)
                    case .spectrogram:
                        drawSpectrogram(context, size: size)
                    case .octaveBars:
                        drawOctaveBars(context, size: size)
                    }
                    drawGrid(context, size: size)
                    drawCurve(
                        context, size: size,
                        bands: shadowBands, color: shadowColor.opacity(0.45),
                        thick: false
                    )
                    drawCurve(
                        context, size: size,
                        bands: bandsForCurve, color: earColor,
                        thick: true
                    )
                    drawNotchMarker(context, size: size)
                    if !readOnly { drawNodes(context, size: size) }
                    drawFrequencyLabels(context, size: size)
                    drawDBLabels(context, size: size)
                }
                .contentShape(Rectangle())
                .modifier(InteractionModifier(active: !readOnly, gesture: dragGesture(in: geo.size)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.85))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Drawing

    private func drawGrid(_ context: GraphicsContext, size: CGSize) {
        let gridColor = GraphicsContext.Shading.color(.white.opacity(0.10))
        let zeroColor = GraphicsContext.Shading.color(.white.opacity(0.30))

        for hz in gridFrequencies {
            let x = xForFreq(hz, width: size.width)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: gridColor, lineWidth: 0.5)
        }

        for db in stride(from: minDB, through: maxDB, by: 6) {
            let y = yForDB(db, height: size.height)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            let shading: GraphicsContext.Shading = (db == 0) ? zeroColor : gridColor
            context.stroke(path, with: shading, lineWidth: db == 0 ? 1 : 0.5)
        }
    }

    private func drawCurve(
        _ context: GraphicsContext,
        size: CGSize,
        bands: [EQBand],
        color: Color,
        thick: Bool
    ) {
        guard !bands.isEmpty else { return }
        var path = Path()
        let columns = Int(size.width)
        for col in 0...columns {
            let x = CGFloat(col)
            let hz = freqForX(x, width: size.width)
            let db = BiquadResponse.compositeMagnitudeDB(at: hz, bands: bands)
            let y = yForDB(db, height: size.height)
            if col == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: thick ? 2.0 : 1.0, lineCap: .round, lineJoin: .round)
        )
    }

    /// Synthesise an extra band from the tinnitus notch so the curve renderer
    /// includes it. `EQBand`'s `notch` filterType + the notch's Q and depth
    /// map naturally to a high-Q biquad bandstop with negative gain.
    private var bandsForCurve: [EQBand] {
        guard let notch, notch.enabled else { return bands }
        let notchBand = EQBand(
            frequencyHz: notch.frequencyHz,
            gaindB: notch.depthdB,
            bandwidth: 1.0 / max(notch.qWidth.qValue, 0.1),
            filterType: .notch,
            enabled: true
        )
        return bands + [notchBand]
    }

    /// Vertical marker + label at the notch frequency. Stays visible even
    /// when the notch isn't rendered as part of the curve (turned off) so
    /// the user always sees where their pitch is set.
    private func drawNotchMarker(_ context: GraphicsContext, size: CGSize) {
        guard let notch else { return }
        let x = xForFreq(notch.frequencyHz, width: size.width)
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        let color: Color = notch.enabled ? .purple : .gray
        context.stroke(
            line,
            with: .color(color.opacity(notch.enabled ? 0.5 : 0.25)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
        )
        let label = Text("notch \(Int(notch.frequencyHz)) Hz")
            .font(.caption2.monospaced())
            .foregroundColor(color.opacity(0.75))
        context.draw(label, at: CGPoint(x: x + 6, y: 14), anchor: .leading)
    }

    private func drawNodes(_ context: GraphicsContext, size: CGSize) {
        for band in bands {
            let p = pointFor(band: band, in: size)
            let isSelected = selectedBandID == band.id
            let core: Color = band.enabled ? earColor : .gray
            let halo: Color = isSelected ? .white : core.opacity(0.7)

            context.fill(
                Path(ellipseIn: CGRect(
                    x: p.x - nodeRadius - 2,
                    y: p.y - nodeRadius - 2,
                    width: (nodeRadius + 2) * 2,
                    height: (nodeRadius + 2) * 2
                )),
                with: .color(halo.opacity(0.3))
            )
            context.fill(
                Path(ellipseIn: CGRect(
                    x: p.x - nodeRadius,
                    y: p.y - nodeRadius,
                    width: nodeRadius * 2,
                    height: nodeRadius * 2
                )),
                with: .color(core)
            )
            context.stroke(
                Path(ellipseIn: CGRect(
                    x: p.x - nodeRadius,
                    y: p.y - nodeRadius,
                    width: nodeRadius * 2,
                    height: nodeRadius * 2
                )),
                with: .color(.white),
                lineWidth: 1.5
            )
        }
    }

    private func drawSpectrum(_ context: GraphicsContext, size: CGSize) {
        guard !spectrumBinsDB.isEmpty else { return }
        let baselineY = size.height
        let topY = size.height * (1 - spectrumHeightFraction)

        // The data is already log-binned — each bucket maps linearly to the
        // visible 20 Hz–20 kHz log range, no per-bin Hz conversion needed.
        let buckets = spectrumBinsDB.count

        var fillPath = Path()
        fillPath.move(to: CGPoint(x: 0, y: baselineY))
        for b in 0..<buckets {
            let x = size.width * CGFloat(b) / CGFloat(max(1, buckets - 1))
            let y = spectrumY(
                dbfs: Double(spectrumBinsDB[b]),
                baseline: baselineY, top: topY
            )
            fillPath.addLine(to: CGPoint(x: x, y: y))
        }
        fillPath.addLine(to: CGPoint(x: size.width, y: baselineY))
        fillPath.closeSubpath()
        context.fill(fillPath, with: .color(.white.opacity(0.18)))

        guard !spectrumPeakHoldDB.isEmpty else { return }
        var peakPath = Path()
        for b in 0..<spectrumPeakHoldDB.count {
            let x = size.width * CGFloat(b) / CGFloat(max(1, spectrumPeakHoldDB.count - 1))
            let y = spectrumY(
                dbfs: Double(spectrumPeakHoldDB[b]),
                baseline: baselineY, top: topY
            )
            if b == 0 { peakPath.move(to: CGPoint(x: x, y: y)) }
            else { peakPath.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(
            peakPath,
            with: .color(.white.opacity(0.55)),
            style: StrokeStyle(lineWidth: 1.0, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawPreSpectrum(_ context: GraphicsContext, size: CGSize) {
        guard !preSpectrumBinsDB.isEmpty else { return }
        let baselineY = size.height
        let topY = size.height * (1 - spectrumHeightFraction)
        let buckets = preSpectrumBinsDB.count
        var path = Path()
        for b in 0..<buckets {
            let x = size.width * CGFloat(b) / CGFloat(max(1, buckets - 1))
            let y = spectrumY(
                dbfs: Double(preSpectrumBinsDB[b]),
                baseline: baselineY, top: topY
            )
            if b == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(
            path,
            with: .color(.cyan.opacity(0.85)),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [4, 2])
        )
    }

    /// Rolling time × frequency heatmap occupying the same bottom band as
    /// the spectrum overlay. Newest column on the right; each column is one
    /// past frame from `spectrumHistory` colored by dB.
    private func drawSpectrogram(_ context: GraphicsContext, size: CGSize) {
        guard !spectrumHistory.isEmpty else { return }
        let baselineY = size.height
        let topY = size.height * (1 - spectrumHeightFraction)
        let height = baselineY - topY
        let frames = spectrumHistory.count
        let bins = spectrumHistory.last?.count ?? 0
        guard bins > 0 else { return }

        let colW = size.width / CGFloat(frames)
        let rowH = height / CGFloat(bins)

        for (frameIdx, column) in spectrumHistory.enumerated() {
            let x = CGFloat(frameIdx) * colW
            for b in 0..<bins {
                let db = Double(column[b])
                // bin 0 = lowest frequency → bottom; flip so high freqs at top
                let y = baselineY - CGFloat(b + 1) * rowH
                let color = Self.heatmapColor(forDB: db)
                let rect = CGRect(x: x, y: y, width: colW + 0.5, height: rowH + 0.5)
                context.fill(Path(rect), with: .color(color))
            }
        }
    }

    /// dB → color map. Below -80 dBFS: nearly black. Above -25 dBFS: hot
    /// red. Mid range blends through blue → cyan → green → yellow.
    static func heatmapColor(forDB db: Double) -> Color {
        let lo: Double = -90
        let hi: Double = -20
        let t = max(0, min(1, (db - lo) / (hi - lo)))
        // 5-stop palette: black/navy → blue → cyan → yellow → red
        let stops: [(Double, Double, Double, Double)] = [
            (0.00, 0.02, 0.02, 0.06),  // near-black
            (0.20, 0.08, 0.12, 0.36),  // deep blue
            (0.45, 0.10, 0.55, 0.85),  // cyan
            (0.70, 0.95, 0.85, 0.20),  // yellow
            (1.00, 0.95, 0.20, 0.15),  // red
        ]
        for i in 0..<(stops.count - 1) {
            let (t0, r0, g0, b0) = stops[i]
            let (t1, r1, g1, b1) = stops[i + 1]
            if t >= t0 && t <= t1 {
                let frac = (t - t0) / (t1 - t0)
                return Color(
                    red: r0 + frac * (r1 - r0),
                    green: g0 + frac * (g1 - g0),
                    blue: b0 + frac * (b1 - b0)
                )
            }
        }
        return Color(red: stops.last!.1, green: stops.last!.2, blue: stops.last!.3)
    }

    /// 1/3-octave bar analyzer. For each ISO band, takes the max dB across
    /// the log-bins falling in the band's width and draws a vertical bar
    /// rising from the canvas baseline, just like a hardware spectrum
    /// analyzer.
    private func drawOctaveBars(_ context: GraphicsContext, size: CGSize) {
        guard !spectrumBinsDB.isEmpty else { return }
        let baselineY = size.height
        let topY = size.height * (1 - spectrumHeightFraction)

        let bins = spectrumBinsDB.count
        let logMin = log10(minHz)
        let logMax = log10(maxHz)
        let logRange = logMax - logMin

        let barFactor = pow(2.0, 1.0 / 6.0)         // half-width of 1/3 octave
        let gap: CGFloat = 1.5

        for centerHz in Self.thirdOctaveCenters where centerHz >= minHz && centerHz <= maxHz {
            let lowHz = centerHz / barFactor
            let highHz = centerHz * barFactor

            let lowFrac = (log10(lowHz) - logMin) / logRange
            let highFrac = (log10(highHz) - logMin) / logRange
            let lowBin = max(0, Int(Double(bins) * lowFrac))
            let highBin = min(bins - 1, Int(Double(bins) * highFrac))
            guard lowBin <= highBin else { continue }

            var peakDB: Float = -120
            for b in lowBin...highBin {
                if spectrumBinsDB[b] > peakDB { peakDB = spectrumBinsDB[b] }
            }
            let topYBar = spectrumY(dbfs: Double(peakDB), baseline: baselineY, top: topY)
            let x0 = CGFloat(lowFrac) * size.width
            let x1 = CGFloat(highFrac) * size.width
            let rect = CGRect(x: x0 + gap / 2, y: topYBar, width: max(1, x1 - x0 - gap), height: baselineY - topYBar)
            context.fill(Path(rect), with: .color(.white.opacity(0.28)))

            // A thin cap at the peak-hold dB for that band
            if !spectrumPeakHoldDB.isEmpty {
                var peakHold: Float = -120
                for b in lowBin...highBin {
                    if spectrumPeakHoldDB[b] > peakHold { peakHold = spectrumPeakHoldDB[b] }
                }
                let capY = spectrumY(dbfs: Double(peakHold), baseline: baselineY, top: topY)
                let cap = CGRect(x: x0 + gap / 2, y: capY - 1, width: max(1, x1 - x0 - gap), height: 1.5)
                context.fill(Path(cap), with: .color(.white.opacity(0.75)))
            }
        }
    }

    /// ISO 1/3-octave center frequencies covering the 20 Hz – 20 kHz
    /// audible range. 31 bands total.
    private static let thirdOctaveCenters: [Double] = [
        25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200,
        250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000,
        2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000
    ]

    private func spectrumY(dbfs: Double, baseline: CGFloat, top: CGFloat) -> CGFloat {
        let clamped = max(spectrumMinDB, min(spectrumMaxDB, dbfs))
        let normalized = (clamped - spectrumMinDB) / (spectrumMaxDB - spectrumMinDB)
        return baseline - CGFloat(normalized) * (baseline - top)
    }

    private func drawFrequencyLabels(_ context: GraphicsContext, size: CGSize) {
        for hz in labeledFrequencies {
            let x = xForFreq(hz, width: size.width)
            let label = formatHz(hz)
            let text = Text(label)
                .font(.caption2.monospaced())
                .foregroundColor(.white.opacity(0.55))
            context.draw(text, at: CGPoint(x: x, y: size.height - 10), anchor: .center)
        }
    }

    private func drawDBLabels(_ context: GraphicsContext, size: CGSize) {
        for db in stride(from: minDB, through: maxDB, by: 12) {
            let y = yForDB(db, height: size.height)
            let label = db > 0 ? "+\(Int(db))" : "\(Int(db))"
            let text = Text(label)
                .font(.caption2.monospaced())
                .foregroundColor(.white.opacity(0.55))
            context.draw(text, at: CGPoint(x: 14, y: y), anchor: .center)
        }
    }

    // MARK: - Gesture

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if let state = dragState {
                    updateBand(state, to: value.location, canvasSize: size)
                } else if let hit = bandUnderCursor(at: value.location, size: size) {
                    dragState = DragState(bandID: hit.id, startBand: hit, canvasSize: size)
                    selectedBandID = hit.id
                }
            }
            .onEnded { _ in
                dragState = nil
            }
    }

    private func updateBand(_ state: DragState, to location: CGPoint, canvasSize: CGSize) {
        guard let idx = bands.firstIndex(where: { $0.id == state.bandID }) else { return }
        let hz = freqForX(location.x, width: canvasSize.width)
        let db = dbForY(location.y, height: canvasSize.height)
        // Read-modify-write the binding ONCE. Two separate writes here would
        // each go through the binding's setter using the stale captured
        // profile, and the second write would clobber the first.
        var next = bands
        next[idx].frequencyHz = max(minHz, min(maxHz, hz))
        next[idx].gaindB = max(minDB, min(maxDB, db))
        bands = next
    }

    private func bandUnderCursor(at point: CGPoint, size: CGSize) -> EQBand? {
        for band in bands {
            let p = pointFor(band: band, in: size)
            let dx = point.x - p.x
            let dy = point.y - p.y
            if dx * dx + dy * dy <= nodeHitRadius * nodeHitRadius {
                return band
            }
        }
        return nil
    }

    // MARK: - Coordinate maps

    private func xForFreq(_ hz: Double, width: CGFloat) -> CGFloat {
        let logF = log10(max(minHz, min(maxHz, hz)))
        let logMin = log10(minHz)
        let logMax = log10(maxHz)
        return width * CGFloat((logF - logMin) / (logMax - logMin))
    }

    private func freqForX(_ x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return minHz }
        let logMin = log10(minHz)
        let logMax = log10(maxHz)
        let frac = max(0, min(1, Double(x / width)))
        return pow(10.0, logMin + frac * (logMax - logMin))
    }

    private func yForDB(_ db: Double, height: CGFloat) -> CGFloat {
        height * CGFloat((maxDB - db) / (maxDB - minDB))
    }

    private func dbForY(_ y: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 0 }
        let frac = Double(y / height)
        return maxDB - frac * (maxDB - minDB)
    }

    private func pointFor(band: EQBand, in size: CGSize) -> CGPoint {
        CGPoint(
            x: xForFreq(band.frequencyHz, width: size.width),
            y: yForDB(band.gaindB, height: size.height)
        )
    }

    // MARK: - Tick generation

    private var gridFrequencies: [Double] {
        [20, 30, 50, 70, 100, 200, 300, 500, 700, 1000, 2000, 3000, 5000, 7000, 10000, 15000, 20000]
    }

    private var labeledFrequencies: [Double] {
        [50, 100, 500, 1000, 5000, 10000]
    }

    private func formatHz(_ hz: Double) -> String {
        if hz >= 1000 {
            let k = hz / 1000
            return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return "\(Int(hz))"
    }
}

/// Conditionally attaches a gesture so readOnly mode is a passive surface.
private struct InteractionModifier<G: Gesture>: ViewModifier {
    let active: Bool
    let gesture: G
    func body(content: Content) -> some View {
        if active {
            content.gesture(gesture)
        } else {
            content
        }
    }
}
