import SwiftUI

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
    var spectrumSampleRate: Double = 48_000
    var earColor: Color = .blue
    var shadowColor: Color = .red
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
                    drawSpectrum(context, size: size)
                    drawPreSpectrum(context, size: size)
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
        .frame(minHeight: 280)
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
