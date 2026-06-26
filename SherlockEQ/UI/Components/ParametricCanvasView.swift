import SwiftUI

/// Underlay mode for the parametric canvas. `.spectrum` keeps the
/// existing line+peak-hold + pre-EQ outline. `.spectrogram` swaps in a
/// rolling time × frequency heatmap. `.octaveBars` collapses the
/// spectrum into 31 ISO 1/3-octave bars.
///
/// NOTE: `.spectrogram` is currently hidden from the user-facing picker
/// (see `userVisibleCases`) — the heatmap + annotation layers are CPU-
/// expensive (~120% during testing) and the feature needs a profiling
/// pass plus a UX review before re-exposing. All draw functions, the
/// `SpectrogramLayerChipStrip`, and the four lens presets remain in
/// the codebase; flipping it back on is just a matter of restoring
/// `.spectrogram` to `userVisibleCases`.
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

    /// Subset of `allCases` that ships to users right now. Spectrogram is
    /// excluded pending a future performance / UX revisit.
    static var userVisibleCases: [CanvasVizMode] {
        allCases.filter { $0 != .spectrogram }
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
    /// Audiogram-derived hearing-correction bands for the *active* ear. Drawn
    /// as a dashed line (the "Correction" layer) and summed with `bands` to
    /// form the solid "Result" curve — what the listener actually hears. Empty
    /// means no audiogram available (or the caller wants the layer hidden).
    var targetBands: [EQBand] = []
    /// Correction bands for the *other* ear, used to compute that ear's Result
    /// curve (the dotted shadow). The audiogram is inherently per-ear, so this
    /// can differ from `targetBands` even when the EQ is edited in lockstep.
    var shadowTargetBands: [EQBand] = []
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

    // MARK: - Layer visibility
    // Each draw call in the body is gated by one of these. Defaults are true
    // so call sites that don't care (Simple/Advanced previews) keep working
    // unchanged; the Expert view drives them from persisted @AppStorage
    // flags via the chip strip.
    var showInputSpectrum: Bool = true
    var showOutputSpectrum: Bool = true
    var showEQCurve: Bool = true
    var showAudiogramTarget: Bool = true
    /// The solid "Result" curve — `bands` summed with the audiogram correction
    /// (`targetBands`), i.e. what the listener actually hears. When on, the EQ
    /// curve drops to a thinner weight so Result reads as the dominant line.
    var showResultCurve: Bool = false
    var showSafetyOverlay: Bool = true
    var showPeakCallouts: Bool = false

    /// Live dynamic-feature contributions to draw as separate animated
    /// strokes under the static EQ curve. Each is one feature's main bell
    /// at its *current* gain delta. Recomputed only in the draw path (the
    /// static `cachedCurveDB` is never touched) and only while non-empty —
    /// the caller passes only features whose delta exceeds the rest
    /// threshold, so at rest nothing animates and nothing recomputes.
    struct DynamicOverlay: Equatable {
        var centerHz: Double
        var q: Double
        var gainDB: Double
    }
    var dynamicOverlays: [DynamicOverlay] = []
    var showDynamicsOverlay: Bool = false

    // MARK: - Spectrogram-mode-specific layer flags
    // Each only consulted when `vizMode == .spectrogram`. Defaults chosen
    // so first-launch users see a sensible annotated heatmap.
    var showNotchLine: Bool = true
    var showRegionLabels: Bool = true
    var showColorLegend: Bool = true
    var showTimeAxis: Bool = true
    var showPersistence: Bool = false

    /// Safe-listening dBA ceiling from the active profile. Drives the
    /// safety-overlay threshold curve via the closed-form
    /// `dBFS = ceiling − calibration − A_weight(f)`. 85 dBA matches NIOSH.
    var safetyCeilingDBA: Double = 85
    /// SPL calibration in dB. With default 100 a 0 dBFS digital signal
    /// represents 100 dB SPL at the listener; setting this to match the
    /// user's actual playback level makes the safety overlay reflect real
    /// loudness instead of acting as a relative cue.
    var calibrationOffsetDBA: Double = 100

    private let minHz: Double = 20
    private let maxHz: Double = 20_000
    private var freqAxis: LogFreqAxis { LogFreqAxis(minHz: minHz, maxHz: maxHz) }
    /// Y-axis range for the EQ curve (dB gain, around 0). Defaults to ±18:
    /// tightened from ±24 so typical bands (mostly ±6 dB) deflect ~33 % more
    /// pixels and the curve reads as a real shape rather than a faint wobble
    /// near zero, with stride-by-6 dividing the axis cleanly. The Expert canvas
    /// passes ±24 to match its own ±24 gain clamp — otherwise a band set to the
    /// extremes via keyboard/import is both undrawable AND silently re-clamped
    /// to ±18 the instant the user drags it (the drag clamp uses this range).
    var gainRangeDB: ClosedRange<Double> = -18...18
    private var minDB: Double { gainRangeDB.lowerBound }
    private var maxDB: Double { gainRangeDB.upperBound }
    private let nodeRadius: CGFloat = 8
    private let nodeHitRadius: CGFloat = 16

    /// Spectrum vertical mapping (dBFS). Per spec §5.9 the analyzer sits
    /// underneath the EQ curve in a constrained band, not over the full
    /// canvas — `spectrumHeightFraction` is how much of the canvas it gets.
    private let spectrumMinDB: Double = -90
    // Top of the dBFS display range. Bumped from -20 → -6 so the safety
    // threshold curve has room to move across the user's full calibration
    // slider — with default ceiling 85 + calibration 100, threshold lands
    // near -15 dBFS at 1 kHz, which used to clip against a -20 ceiling.
    // Most music spectrum content sits well below -20, so the extra ~14 dB
    // of headroom is "threshold + danger fill" territory rather than
    // crowding the silhouette.
    private let spectrumMaxDB: Double = -6
    /// Mode-aware: the heatmap needs much more vertical room than a thin
    /// silhouette overlay, so Spectrogram mode gets 65% of the canvas
    /// versus Spectrum / Bars at 70%. (40 → 50 in commit 10445ea when the
    /// Expert canvas grew to 450pt; 50 → 70 for 0.1.3 to give the
    /// iQualize-style live overlay enough vertical room to read as a
    /// proper background fill rather than a ribbon at the bottom.)
    /// The EQ curve, grid, and labels continue to draw across the
    /// full canvas — they just sit in a smaller proportion of it
    /// when the spectrogram is large.
    private var spectrumHeightFraction: CGFloat {
        vizMode == .spectrogram ? 0.65 : 0.7
    }

    @State private var dragState: DragState?
    /// Pointer position in canvas coordinates, while the user hovers over
    /// the canvas. Drives the cursor-readout overlay; nil when the pointer
    /// has left the canvas. Set via `.onContinuousHover`.
    @State private var hoverLocation: CGPoint? = nil

    // MARK: - Accessibility environment
    /// `Reduce Transparency` — push gradient / line opacities toward solid
    /// so users with low contrast sensitivity can read the layers cleanly.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// `Differentiate Without Color` — guarantees pattern (dashed/dotted/
    /// solid) carries the signal in addition to hue. Most layers already do
    /// this; this hook lets us force a fallback where redundancy is weak.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    /// Cached log-frequency-spaced dB samples for the active curve. Rebuilt
    /// only when `bands` or `notch` changes — NOT on every spectrum frame.
    /// Each Canvas redraw then just strokes a path through the cached values
    /// (linear arithmetic) instead of re-running the cookbook coefficient +
    /// magnitude math for every column on every frame.
    @State private var cachedCurveDB: [Double] = []
    /// Same idea for the other-ear "shadow" trace.
    @State private var cachedShadowDB: [Double] = []
    /// And the audiogram-derived "target"/correction trace.
    @State private var cachedTargetDB: [Double] = []
    /// The "Result" trace (active ear = `bands` + correction) and its
    /// other-ear shadow. Cached on the same edit cadence as the rest.
    @State private var cachedResultDB: [Double] = []
    @State private var cachedResultShadowDB: [Double] = []
    /// Other-ear correction trace (for the per-ear Correction line).
    @State private var cachedTargetShadowDB: [Double] = []

    /// How many log-spaced samples to compute per curve. 512 across a typical
    /// 600–900px wide canvas means ~1.5px between samples; the Path's line
    /// segments interpolate the rest. Visually indistinguishable from the
    /// previous per-pixel computation, but ~30× fewer biquad evaluations.
    private static let curveSampleCount = 512

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
                        // Pre-EQ first so the post-EQ silhouette sits ON TOP
                        // of it — reads as "what's coming in" behind "what's
                        // leaving the chain". Reference-image hierarchy.
                        if showInputSpectrum { drawPreSpectrum(context, size: size) }
                        if showOutputSpectrum { drawSpectrum(context, size: size) }
                        if showSafetyOverlay { drawSafetyOverlay(context, size: size) }
                        if showPeakCallouts { drawPeakCallouts(context, size: size) }
                    case .spectrogram:
                        drawSpectrogram(context, size: size)
                        // Spectrogram-only overlays. Order matters: heatmap
                        // first, then persistence highlight (sits on top of
                        // the heatmap colours), then annotations (axis,
                        // labels, legend) on top of everything.
                        if showPersistence { drawPersistence(context, size: size) }
                        if showNotchLine { drawNotchLine(context, size: size) }
                        if showTimeAxis { drawTimeAxis(context, size: size) }
                        if showRegionLabels { drawFrequencyRegionLabels(context, size: size) }
                        if showColorLegend { drawColorLegend(context, size: size) }
                    case .octaveBars:
                        drawOctaveBars(context, size: size)
                    }
                    drawGrid(context, size: size)
                    // Transfer curves. Consistent encoding: hue = ear
                    // (earColor active / shadowColor other), style = type
                    // (dotted EQ, dashed Correction, solid-thick Result).
                    // Drawn least-dominant first so Result lands on top, and
                    // the other-ear (shadow-hue) line under its active twin.
                    // Other-ear lines only when the ears actually differ — a
                    // symmetric profile draws one line per type.
                    let drawOtherEar = earsAsymmetric
                    if showAudiogramTarget {
                        if drawOtherEar {
                            drawTypedCurve(context, size: size, cachedDB: cachedTargetShadowDB, color: shadowColor, kind: .correction)
                        }
                        drawTypedCurve(context, size: size, cachedDB: cachedTargetDB, color: earColor, kind: .correction)
                    }
                    // Live dynamic-feature bells — under the static curves.
                    if showDynamicsOverlay { drawDynamicsOverlay(context, size: size) }
                    if showEQCurve {
                        if drawOtherEar {
                            drawTypedCurve(context, size: size, cachedDB: cachedShadowDB, color: shadowColor, kind: .eq)
                        }
                        drawTypedCurve(context, size: size, cachedDB: cachedCurveDB, color: earColor, kind: .eq)
                    }
                    if showResultCurve {
                        if drawOtherEar {
                            drawTypedCurve(context, size: size, cachedDB: cachedResultShadowDB, color: shadowColor, kind: .result)
                        }
                        drawTypedCurve(context, size: size, cachedDB: cachedResultDB, color: earColor, kind: .result)
                    }
                    drawNotchMarker(context, size: size)
                    // Editable handles show whenever an EQ-derived curve is
                    // visible — either the EQ-only trace or the Result line —
                    // so dragging works even when only Result is shown.
                    if !readOnly && (showEQCurve || showResultCurve) { drawNodes(context, size: size) }
                    drawFrequencyLabels(context, size: size)
                    drawDBLabels(context, size: size)
                }
                .contentShape(Rectangle())
                .modifier(InteractionModifier(active: !readOnly, gesture: dragGesture(in: geo.size)))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hoverLocation = location
                    case .ended: hoverLocation = nil
                    }
                }
                // Curve legend (native text so it scales with Dynamic Type).
                // Top-leading, click-through, only in the curve scene.
                if vizMode == .spectrum {
                    curveLegend
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(8)
                        .allowsHitTesting(false)
                }
                // Cursor readout: a small native-text overlay positioned
                // near the pointer. SwiftUI's body-level Text scales with
                // Dynamic Type for free, which we couldn't get from a
                // GraphicsContext.draw inside the Canvas closure.
                if let loc = hoverLocation {
                    cursorReadout(at: loc, in: geo.size)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(reduceTransparency ? 0.98 : 0.85))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // VoiceOver summary — the canvas is visual-only, but a one-sentence
        // description gives non-sighted users state context without forcing
        // them to step through every element.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Frequency response chart")
        .accessibilityValue(accessibilitySummary)
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear { recomputeCachedCurves() }
        .onChange(of: bands) { _, _ in recomputeCachedCurves() }
        .onChange(of: shadowBands) { _, _ in recomputeCachedCurves() }
        .onChange(of: targetBands) { _, _ in recomputeCachedCurves() }
        .onChange(of: shadowTargetBands) { _, _ in recomputeCachedCurves() }
        .onChange(of: notch) { _, _ in recomputeCachedCurves() }
        // Peak chips are sticky — recomputed only when fresh spectrum data
        // arrives, not on every body re-eval, so chips don't churn across
        // unrelated invalidations.
        .onChange(of: spectrumBinsDB) { _, _ in updateStickyPeaks() }
    }

    /// Resample active, shadow, and target curves into `cached*DB`. Cheap
    /// when bands are static (one pass on edit); free on subsequent frames.
    private func recomputeCachedCurves() {
        cachedCurveDB = sampledDB(for: bandsForCurve)
        cachedShadowDB = sampledDB(for: shadowBands)
        cachedTargetDB = sampledDB(for: targetBands)
        // Result = what's heard: the EQ curve summed (in dB, via cascade) with
        // the audiogram correction. Computed per ear so an asymmetric audiogram
        // shows two Result lines even when the EQ is edited in lockstep.
        cachedResultDB = sampledDB(for: bandsForCurve + targetBands)
        cachedResultShadowDB = sampledDB(for: shadowBands + shadowTargetBands)
        cachedTargetShadowDB = sampledDB(for: shadowTargetBands)
    }

    /// True when the two ears' curves differ audibly — drives whether the
    /// right-ear (shadow-hue) lines and the legend's Left/Right split are
    /// shown. Symmetric profiles draw one line per type and a simpler legend.
    private var earsAsymmetric: Bool {
        !bands.audiblyEquivalent(to: shadowBands)
            || !targetBands.audiblyEquivalent(to: shadowTargetBands)
    }

    private func sampledDB(for bands: [EQBand]) -> [Double] {
        guard !bands.isEmpty else { return [] }
        let n = Self.curveSampleCount
        let axis = freqAxis
        var arr = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let frac = Double(i) / Double(n - 1)
            let hz = axis.hz(forFrac: frac)
            arr[i] = BiquadResponse.compositeMagnitudeDB(at: hz, bands: bands)
        }
        return arr
    }

    // MARK: - Drawing

    private func drawGrid(_ context: GraphicsContext, size: CGSize) {
        let gridColor = GraphicsContext.Shading.color(.white.opacity(a11yOpacity(0.10, reduceFactor: 2.0)))
        let zeroColor = GraphicsContext.Shading.color(.white.opacity(a11yOpacity(0.30, reduceFactor: 2.0)))

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

    // MARK: - Accessibility helpers

    /// Scale `alpha` by `factor` when `accessibilityReduceTransparency` is
    /// on so translucent fills become legible against the dark background.
    /// 1.0 hard-caps so we don't pass invalid alpha to Color.
    private func a11yOpacity(_ alpha: Double, reduceFactor: Double = 2.5) -> Double {
        reduceTransparency ? min(1.0, alpha * reduceFactor) : alpha
    }

    /// One-sentence summary of the visible canvas state for VoiceOver. Read
    /// out whenever SwiftUI re-evaluates the accessibilityValue (i.e. on
    /// state change). Kept short — VoiceOver users don't want a paragraph.
    private var accessibilitySummary: String {
        var parts: [String] = []
        let activeCount = bandsForCurve.filter { $0.enabled }.count
        parts.append("\(activeCount) band\(activeCount == 1 ? "" : "s") active")
        if let peak = spectrumPeakDescription() {
            parts.append(peak)
        }
        if let notch, notch.enabled {
            parts.append("Tinnitus notch at \(Int(notch.frequencyHz)) Hz, depth \(Int(notch.depthdB)) dB")
        }
        return parts.joined(separator: ". ")
    }

    /// Locate the loudest live spectrum bin and return a phrase like
    /// "Peak at 1.2 kHz, -28 dBFS". Nil when no spectrum data yet.
    private func spectrumPeakDescription() -> String? {
        guard !spectrumBinsDB.isEmpty else { return nil }
        var bestIdx = 0
        var bestDB: Float = -200
        for (i, db) in spectrumBinsDB.enumerated() where db > bestDB {
            bestDB = db
            bestIdx = i
        }
        let buckets = spectrumBinsDB.count
        let frac = Double(bestIdx) / Double(max(1, buckets - 1))
        let hz = freqAxis.hz(forFrac: frac)
        let hzLabel = hz >= 1000 ? String(format: "%.1f kHz", hz / 1000) : "\(Int(hz)) Hz"
        return "Peak at \(hzLabel), \(Int(bestDB.rounded())) dBFS"
    }

    // MARK: - Transfer curves

    /// The three transfer-curve types. Encoding is two-dimensional and each
    /// dimension carries a redundant non-colour signal so the chart stays
    /// legible for colour-vision-deficient users:
    ///   • **hue** = ear (active/earColor vs other/shadowColor), labelled in
    ///     the legend with "Left"/"Right" text — never colour alone.
    ///   • **line style + weight** = type (solid-thick Result, dotted EQ,
    ///     dashed Correction), also labelled in the legend.
    enum CurveKind { case result, eq, correction }

    private func strokeStyle(for kind: CurveKind) -> StrokeStyle {
        switch kind {
        case .result:     return StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)
        case .eq:         return StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round, dash: [2, 3.5])
        case .correction: return StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round, dash: [6, 4])
        }
    }

    /// Opacity per type — Result is the opaque hero; EQ/Correction read as
    /// lighter contributors. Bumped under Reduce Transparency for legibility.
    private func opacity(for kind: CurveKind) -> Double {
        switch kind {
        case .result:     return 1.0
        case .eq:         return a11yOpacity(0.85, reduceFactor: 1.15)
        case .correction: return a11yOpacity(0.7, reduceFactor: 1.3)
        }
    }

    /// Draw one transfer curve with the type's style in the given ear hue.
    private func drawTypedCurve(
        _ context: GraphicsContext,
        size: CGSize,
        cachedDB: [Double],
        color: Color,
        kind: CurveKind
    ) {
        guard cachedDB.count > 1 else { return }
        var path = Path()
        let n = cachedDB.count
        let denom = CGFloat(n - 1)
        for i in 0..<n {
            let x = CGFloat(i) / denom * size.width
            let y = yForDB(cachedDB[i], height: size.height)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(path, with: .color(color.opacity(opacity(for: kind))), style: strokeStyle(for: kind))
    }

    // MARK: - Legend

    /// On-canvas legend keyed to the same two-dimensional encoding the curves
    /// use: line **style** → type, line **colour** → ear. Both axes carry text
    /// labels, so nothing depends on colour alone. Shown only when it adds
    /// information — i.e. more than one curve type is visible, or the two ears
    /// differ (so the Left/Right colour key matters). A single symmetric line
    /// needs no legend.
    @ViewBuilder
    private var curveLegend: some View {
        let types: [(CurveKind, String)] = {
            var t: [(CurveKind, String)] = []
            if showResultCurve { t.append((.result, "Result")) }
            if showEQCurve { t.append((.eq, "EQ")) }
            if showAudiogramTarget { t.append((.correction, "Correction")) }
            return t
        }()
        if !types.isEmpty && (types.count > 1 || earsAsymmetric) {
            // When both ears are drawn the line samples stay neutral (the ear
            // key carries colour); when symmetric, tint them the single hue
            // in play so the sample matches the on-screen line.
            let sampleColor: Color = earsAsymmetric ? .white.opacity(0.9) : earColor
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(types.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 6) {
                        legendSampleLine(item.0, color: sampleColor)
                        Text(item.1).font(.caption2)
                    }
                }
                if earsAsymmetric {
                    Divider().frame(width: 92)
                    HStack(spacing: 12) {
                        legendEarKey(earColor, "Left")
                        legendEarKey(shadowColor, "Right")
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.black.opacity(reduceTransparency ? 0.85 : 0.5))
            )
        }
    }

    /// A short line drawn in the type's exact stroke style — the redundant
    /// non-colour signal for "which type is this".
    private func legendSampleLine(_ kind: CurveKind, color: Color) -> some View {
        Canvas { ctx, size in
            var p = Path()
            p.move(to: CGPoint(x: 1, y: size.height / 2))
            p.addLine(to: CGPoint(x: size.width - 1, y: size.height / 2))
            ctx.stroke(p, with: .color(color), style: strokeStyle(for: kind))
        }
        .frame(width: 26, height: 10)
    }

    private func legendEarKey(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(.caption2)
        }
    }

    /// Draw each live dynamic-feature bell as a dashed, ear-tinted stroke.
    /// Computed on the fly (coarser than the 512-sample static cache — a
    /// single smooth bell needs far fewer points) so it never disturbs the
    /// cached static curve. Only invoked when `dynamicOverlays` is non-empty,
    /// which the caller drives at the meter rate (≤ 20 Hz) and only for
    /// triggered features — so this is free at rest. The stroke reflects the
    /// current delta as data, with no implicit SwiftUI animation, so it
    /// snaps to the live value (Reduce Motion-friendly by construction).
    private func drawDynamicsOverlay(_ context: GraphicsContext, size: CGSize) {
        guard !dynamicOverlays.isEmpty else { return }
        let n = 128
        let axis = freqAxis
        let denom = CGFloat(n - 1)
        for overlay in dynamicOverlays {
            let band = EQBand(
                frequencyHz: overlay.centerHz,
                gaindB: overlay.gainDB,
                bandwidth: overlay.q,
                filterType: .parametric,
                enabled: true
            )
            var path = Path()
            for i in 0..<n {
                let frac = Double(i) / Double(n - 1)
                let hz = axis.hz(forFrac: frac)
                let db = BiquadResponse.compositeMagnitudeDB(at: hz, bands: [band])
                let x = CGFloat(i) / denom * size.width
                let y = yForDB(db, height: size.height)
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(
                path,
                with: .color(earColor.opacity(a11yOpacity(0.7, reduceFactor: 1.3))),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [3, 3])
            )
        }
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
        var points: [CGPoint] = []
        points.reserveCapacity(buckets)
        for b in 0..<buckets {
            let x = size.width * CGFloat(b) / CGFloat(max(1, buckets - 1))
            let y = spectrumY(
                dbfs: Double(spectrumBinsDB[b]),
                baseline: baselineY, top: topY
            )
            points.append(CGPoint(x: x, y: y))
        }

        // Smooth top edge using a quadratic-through-midpoints pass over the
        // raw log-binned points. Doesn't overshoot the way Catmull-Rom can,
        // so peaks stay where they belong while jaggies between bins melt
        // out.
        let topCurve = Self.smoothCurve(through: points)

        var fillPath = topCurve
        fillPath.addLine(to: CGPoint(x: size.width, y: baselineY))
        fillPath.addLine(to: CGPoint(x: 0, y: baselineY))
        fillPath.closeSubpath()

        // Violet gradient — saturated and dense near the base, fading
        // toward the spectrum ceiling so the eye reads the silhouette
        // rather than a flat slab. Distinct from the blue/red EQ-curve
        // hues so the curve still stands out over the analyzer.
        // Opacity ramped up when `Reduce Transparency` is on so the
        // silhouette stays readable for users with low contrast sensitivity.
        let fillTop = Color(red: 0.55, green: 0.30, blue: 0.78).opacity(a11yOpacity(0.10, reduceFactor: 3.0))
        let fillMid = Color(red: 0.48, green: 0.22, blue: 0.72).opacity(a11yOpacity(0.55, reduceFactor: 1.5))
        let fillBottom = Color(red: 0.38, green: 0.15, blue: 0.62).opacity(a11yOpacity(0.85, reduceFactor: 1.15))
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [
                .init(color: fillTop, location: 0),
                .init(color: fillMid, location: 0.55),
                .init(color: fillBottom, location: 1)
            ]),
            startPoint: CGPoint(x: 0, y: topY),
            endPoint: CGPoint(x: 0, y: baselineY)
        )
        context.fill(fillPath, with: shading)

        // Crisp white outline along the top of the fill so the silhouette
        // reads even when the gradient washes out at the tip.
        context.stroke(
            topCurve,
            with: .color(.white.opacity(0.75)),
            style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
        )

        // Peak-hold envelope rides with the "Peaks" chip (showPeakCallouts),
        // not the Output layer itself — so an Output-only view is a clean
        // silhouette and the faint hold line only appears alongside the peak
        // callouts (Compare / Loudness lenses, or the Peaks chip on its own).
        guard showPeakCallouts, !spectrumPeakHoldDB.isEmpty else { return }
        var peakPoints: [CGPoint] = []
        peakPoints.reserveCapacity(spectrumPeakHoldDB.count)
        for b in 0..<spectrumPeakHoldDB.count {
            let x = size.width * CGFloat(b) / CGFloat(max(1, spectrumPeakHoldDB.count - 1))
            let y = spectrumY(
                dbfs: Double(spectrumPeakHoldDB[b]),
                baseline: baselineY, top: topY
            )
            peakPoints.append(CGPoint(x: x, y: y))
        }
        context.stroke(
            Self.smoothCurve(through: peakPoints),
            with: .color(.white.opacity(0.35)),
            style: StrokeStyle(lineWidth: 0.75, lineCap: .round, lineJoin: .round)
        )
    }

    // MARK: - Peak callouts

    /// How many peaks to label at once. More than ~5 turns into visual
    /// clutter; this matches the reference-image cap of five.
    private static let maxPeakCallouts = 5

    /// Minimum dBFS for a bin to even be considered a peak candidate. Keeps
    /// callouts off the noise floor when the source is quiet.
    private static let peakFloorDBFS: Float = -65

    /// Minimum prominence (dB above local neighbours) before a local max is
    /// labelled. Stops "barely a bump" wobbles from getting a chip.
    private static let peakProminenceDB: Float = 2.5

    /// Minimum bucket-index separation between two labelled peaks. Prevents
    /// adjacent samples on a wide hump from each getting their own chip.
    /// 8 buckets ≈ 1/10 of a decade in the current 256-bucket grid.
    private static let peakMinSeparation = 8

    /// Minimum horizontal gap *in points* between two adjacent chip rects.
    /// The bucket-space check above is a prefilter; this is what actually
    /// prevents chips from visually overlapping each other on screen,
    /// because chip width (44–56pt) is much larger than the pixel-distance
    /// between adjacent buckets in the low/mid range.
    private static let peakChipPixelSeparation: CGFloat = 62

    /// Minimum horizontal gap from a band node to a peak chip. Nodes are
    /// interactive — peaks colliding with them would compete for clicks
    /// and crowd the user's editing surface. When a peak falls inside this
    /// keepout, the chip is dropped rather than displaced.
    private static let peakChipNodeKeepout: CGFloat = 36

    /// How many spectrum frames a sticky peak survives without a match
    /// before being dropped. At 20 Hz publishes, 5 frames ≈ 250 ms — long
    /// enough to ride out a brief dip below the prominence threshold so
    /// chips don't flicker when audio fluctuates around the edge.
    private static let peakStickyFrames = 5
    /// Bucket-distance tolerance for matching this frame's candidate to
    /// last frame's sticky peak. Generous enough to forgive small shifts
    /// in where the analyzer placed a moving peak, tight enough to stop
    /// two genuinely different peaks from being treated as the same one.
    private static let peakMatchTolerance = 6
    /// Position deadband: a sticky peak's bucket index only updates when
    /// the new candidate is more than this many buckets away. Below the
    /// deadband the chip stays put — small frame-to-frame shifts no
    /// longer cause horizontal jitter.
    private static let peakPositionDeadband = 3

    /// Persistent peak state. Each entry survives across spectrum frames
    /// so chips don't blink in and out — only updated when fresh data
    /// arrives (see `updateStickyPeaks`).
    @State private var stickyPeaks: [StickyPeak] = []

    private struct StickyPeak: Identifiable {
        let id = UUID()
        var bucketIdx: Int
        var db: Float
        /// Number of consecutive frames this peak failed to match a fresh
        /// candidate. 0 means matched this frame; ≥ `peakStickyFrames`
        /// means the peak is dropped on the next update.
        var staleFrames: Int = 0
    }

    /// Recompute the sticky peak list from the latest spectrum frame.
    /// Called once per fresh `spectrumBinsDB` update (via `.onChange`), NOT
    /// on every body re-eval. This is what makes chips "lock" instead of
    /// flickering when prominence dips momentarily.
    ///
    /// Strategy:
    /// 1. Find this frame's candidates (same local-max + prominence test
    ///    as before).
    /// 2. Match each existing sticky peak to the closest candidate within
    ///    `peakMatchTolerance` — matched peaks reset `staleFrames` to 0
    ///    and update their dB (and bucket index, with a deadband).
    /// 3. Unmatched sticky peaks age — when `staleFrames >= peakStickyFrames`
    ///    they're dropped. Until then they remain visible.
    /// 4. Unmatched candidates become new sticky peaks, loudest-first, up
    ///    to `maxPeakCallouts` total. New peaks only added if they aren't
    ///    already represented (avoids double-counting).
    private func updateStickyPeaks() {
        guard !spectrumBinsDB.isEmpty else {
            if !stickyPeaks.isEmpty { stickyPeaks = [] }
            return
        }
        let buckets = spectrumBinsDB.count

        // Pass 1 — fresh candidates (local max + floor + prominence).
        var freshCandidates: [(idx: Int, db: Float)] = []
        for i in 1..<(buckets - 1) {
            let here = spectrumBinsDB[i]
            guard here >= Self.peakFloorDBFS else { continue }
            guard here > spectrumBinsDB[i - 1] && here > spectrumBinsDB[i + 1] else { continue }
            let lo = max(0, i - 6)
            let hi = min(buckets - 1, i + 6)
            var minNear: Float = here
            for j in lo...hi { minNear = min(minNear, spectrumBinsDB[j]) }
            guard here - minNear >= Self.peakProminenceDB else { continue }
            freshCandidates.append((i, here))
        }

        // Pass 2 — match existing sticky peaks to candidates.
        var nextSticky: [StickyPeak] = []
        var consumedCandidates = Set<Int>()
        for var peak in stickyPeaks {
            var bestCandIdx: Int? = nil
            var bestDistance = Int.max
            for (ci, cand) in freshCandidates.enumerated()
                where !consumedCandidates.contains(ci) {
                let dist = abs(cand.idx - peak.bucketIdx)
                if dist > Self.peakMatchTolerance { continue }
                if dist < bestDistance {
                    bestDistance = dist
                    bestCandIdx = ci
                }
            }
            if let ci = bestCandIdx {
                let cand = freshCandidates[ci]
                // Deadband on position — small shifts don't move the chip,
                // bigger shifts do. Eliminates frame-to-frame x-jitter.
                if abs(cand.idx - peak.bucketIdx) > Self.peakPositionDeadband {
                    peak.bucketIdx = cand.idx
                }
                peak.db = cand.db
                peak.staleFrames = 0
                consumedCandidates.insert(ci)
                nextSticky.append(peak)
            } else {
                peak.staleFrames += 1
                if peak.staleFrames < Self.peakStickyFrames {
                    nextSticky.append(peak)
                }
                // else: peak drops out (returned to candidate pool only if
                // a new spectrum frame produces it again).
            }
        }

        // Pass 3 — promote loudest unmatched candidates to new sticky peaks
        // until we hit the cap. Filter against bucket-tolerance to anything
        // already in `nextSticky` so a candidate near an existing sticky
        // peak we couldn't match doesn't become a duplicate.
        var unmatched: [(idx: Int, db: Float)] = []
        for (ci, c) in freshCandidates.enumerated()
            where !consumedCandidates.contains(ci) {
            unmatched.append(c)
        }
        unmatched.sort { $0.db > $1.db }
        for cand in unmatched {
            if nextSticky.count >= Self.maxPeakCallouts { break }
            let collides = nextSticky.contains {
                abs($0.bucketIdx - cand.idx) < Self.peakMatchTolerance
            }
            if collides { continue }
            nextSticky.append(StickyPeak(bucketIdx: cand.idx, db: cand.db, staleFrames: 0))
        }

        // Cap (shouldn't fire if matching is correct, but be defensive).
        if nextSticky.count > Self.maxPeakCallouts {
            nextSticky.sort { $0.db > $1.db }
            nextSticky = Array(nextSticky.prefix(Self.maxPeakCallouts))
        }

        stickyPeaks = nextSticky
    }

    /// Render the sticky peak list. Pixel-space chip-collision and band-
    /// node keepout are applied at DRAW time (not at update time) because
    /// node positions can change between updates without the spectrum
    /// changing — and we want chips to dodge nodes the user just moved
    /// even if no new spectrum frame has arrived.
    private func drawPeakCallouts(_ context: GraphicsContext, size: CGSize) {
        guard !stickyPeaks.isEmpty, !spectrumBinsDB.isEmpty else { return }
        let buckets = spectrumBinsDB.count
        let baselineY = size.height
        let topY = size.height * (1 - spectrumHeightFraction)

        // Order sticky peaks by dB (loudest wins ties in chip-collision
        // filtering — same as the original draw order).
        let ordered = stickyPeaks.sorted { $0.db > $1.db }
        let nodeXs: [CGFloat] = bands.map { xForFreq($0.frequencyHz, width: size.width) }
        // Notch marker label lives at the top of the canvas next to its
        // dashed vertical line. Treat it like a band node for keepout
        // purposes — it's user-set and persistent, peak chips are
        // transient, so peaks yield when they'd land on the notch.
        let notchX: CGFloat? = (notch?.enabled == true)
            ? xForFreq(notch!.frequencyHz, width: size.width)
            : nil

        var drawList: [(peak: StickyPeak, x: CGFloat)] = []
        for peak in ordered {
            let frac = Double(peak.bucketIdx) / Double(max(1, buckets - 1))
            let x = CGFloat(frac) * size.width
            if drawList.contains(where: { abs($0.x - x) < Self.peakChipPixelSeparation }) { continue }
            if nodeXs.contains(where: { abs($0 - x) < Self.peakChipNodeKeepout }) { continue }
            // Notch keepout — same distance as nodes since the notch label
            // is roughly the same width as a peak chip.
            if let nx = notchX, abs(nx - x) < Self.peakChipNodeKeepout { continue }
            drawList.append((peak, x))
        }

        // Resolve once.
        let chipFill = Color(red: 1.0, green: 0.82, blue: 0.30).opacity(a11yOpacity(0.92, reduceFactor: 1.05))
        let chipStroke = Color(red: 1.0, green: 0.70, blue: 0.20).opacity(a11yOpacity(0.85, reduceFactor: 1.15))
        let textColor = Color(red: 0.18, green: 0.13, blue: 0.05)
        let dotColor = chipStroke

        // Fixed top row for ALL chips so they read as a single header
        // across the spectrum. Vertical distance to each peak is carried
        // by the hairline connector — keeping chips on a common baseline
        // makes the row scan-able left-to-right by frequency.
        let chipH: CGFloat = 18
        let chipTopInset: CGFloat = 8

        for (peak, x) in drawList {
            let frac = Double(peak.bucketIdx) / Double(max(1, buckets - 1))
            let hz = freqAxis.hz(forFrac: frac)
            let peakY = spectrumY(dbfs: Double(peak.db), baseline: baselineY, top: topY)

            // Liveness — 1.0 while the peak is matching fresh data, ramps
            // toward 0 as `staleFrames` climbs to `peakStickyFrames`.
            // Multiplied into every layer's opacity so the chip + connector
            // + dot fade together over ~250 ms instead of vanishing in one
            // frame. `Color.opacity(_:)` multiplies the existing alpha.
            let liveness: Double = {
                let t = Double(peak.staleFrames) / Double(Self.peakStickyFrames)
                return max(0, 1.0 - t)
            }()

            // Small dot at the peak position.
            let dotR: CGFloat = 2.5
            context.fill(
                Path(ellipseIn: CGRect(
                    x: x - dotR, y: peakY - dotR,
                    width: dotR * 2, height: dotR * 2
                )),
                with: .color(dotColor.opacity(liveness))
            )

            let label = formatPeakHz(hz)
            let chipW: CGFloat = label.count >= 6 ? 56 : 44
            let chipX = max(2, min(size.width - chipW - 2, x - chipW / 2))
            let chipRect = CGRect(x: chipX, y: chipTopInset, width: chipW, height: chipH)

            // Connector line from dot up to chip bottom. Drawn first so the
            // chip sits on top of it. Hidden when there's no vertical room
            // between chip and peak (very rare with the fixed top row).
            if chipRect.maxY < peakY - 2 {
                var line = Path()
                line.move(to: CGPoint(x: x, y: peakY - dotR))
                line.addLine(to: CGPoint(x: chipRect.midX, y: chipRect.maxY))
                context.stroke(
                    line,
                    with: .color(dotColor.opacity(0.65 * liveness)),
                    style: StrokeStyle(lineWidth: 1)
                )
            }

            // Chip background + stroke.
            let chipPath = Path(roundedRect: chipRect, cornerRadius: 4)
            context.fill(chipPath, with: .color(chipFill.opacity(liveness)))
            context.stroke(chipPath, with: .color(chipStroke.opacity(liveness)), lineWidth: 0.75)

            // Chip text — body-size monospaced so digits don't jitter; tinted
            // dark against the amber fill for guaranteed readability.
            let text = Text(label)
                .font(.caption.monospaced().weight(.medium))
                .foregroundColor(textColor.opacity(liveness))
            context.draw(text, at: CGPoint(x: chipRect.midX, y: chipRect.midY), anchor: .center)
        }
    }

    /// Compact frequency label for peak chips ("1.2 kHz" / "440 Hz").
    private func formatPeakHz(_ hz: Double) -> String {
        if hz >= 10_000 {
            return String(format: "%.0f kHz", hz / 1000)
        }
        if hz >= 1_000 {
            return String(format: "%.1f kHz", hz / 1000)
        }
        return "\(Int(hz.rounded())) Hz"
    }

    // MARK: - Safety overlay

    /// Per-frequency safety threshold in dBFS, derived from:
    ///   dBA(f) = dBFS + calibration + A_weight(f)
    /// Solving for the dBFS at which a sustained pure tone of frequency
    /// `f` would contribute the safety ceiling (in dBA):
    ///   threshold_dBFS(f) = ceiling − calibration − A_weight(f) − binOffset
    ///
    /// At 1 kHz `A_weight ≈ 0`, so the threshold is `ceiling − calibration`
    /// — e.g. an 85 dBA ceiling with default 100 dB calibration gives
    /// −15 dBFS. At low/high frequencies `A_weight` is strongly negative
    /// so the threshold *rises*: the ear is less sensitive there, so more
    /// raw SPL is allowed before the dBA reading hits the ceiling. The
    /// resulting curve dips in the 2–5 kHz cochlea-sensitive range.
    ///
    /// `binOffset` compensates for the gap between *time-domain RMS dBFS*
    /// (which is what the Safe Listening dBA meter integrates) and the
    /// *per-FFT-bin dBFS* (which is what the spectrum overlay and the
    /// bars actually read). Hann windowing distributes a sine's energy
    /// across ~4 FFT bins, leaving each individual bin's peak energy
    /// ~6 dB below the tone's RMS. For broadband content the gap is
    /// larger as energy spreads further. Without this offset, bars never
    /// turn amber/red even when the dBA meter shows the user is well
    /// above their ceiling — the math was technically right but the
    /// comparison was apples-to-oranges. 12 dB is the empirical fit that
    /// makes the bar warnings line up with Safe Listening's "Loud" state.
    private static let safetyBinEnergyOffsetDB: Double = 12
    private func safetyThresholdDBFS(at hz: Double) -> Double {
        let aw = SpectrumAnalyzer.aWeightDB(frequencyHz: hz)
        return safetyCeilingDBA - calibrationOffsetDBA - aw - Self.safetyBinEnergyOffsetDB
    }

    /// Draw the safety threshold line plus an amber "danger" fill in any
    /// continuous regions where the live spectrum exceeds the threshold.
    /// Always-on; the threshold line is faint enough to ignore until a
    /// peak rises past it.
    private func drawSafetyOverlay(_ context: GraphicsContext, size: CGSize) {
        guard !spectrumBinsDB.isEmpty else { return }
        let baselineY = size.height
        let topY = size.height * (1 - spectrumHeightFraction)
        let buckets = spectrumBinsDB.count

        // Build spectrum + threshold curves over the same x-axis.
        var spectrumPoints: [CGPoint] = []
        var thresholdPoints: [CGPoint] = []
        spectrumPoints.reserveCapacity(buckets)
        thresholdPoints.reserveCapacity(buckets)
        let axis = freqAxis
        for b in 0..<buckets {
            let frac = Double(b) / Double(max(1, buckets - 1))
            let hz = axis.hz(forFrac: frac)
            let x = size.width * CGFloat(b) / CGFloat(max(1, buckets - 1))
            let specY = spectrumY(
                dbfs: Double(spectrumBinsDB[b]),
                baseline: baselineY, top: topY
            )
            let threshY = spectrumY(
                dbfs: safetyThresholdDBFS(at: hz),
                baseline: baselineY, top: topY
            )
            spectrumPoints.append(CGPoint(x: x, y: specY))
            thresholdPoints.append(CGPoint(x: x, y: threshY))
        }

        // Amber danger fill — closed paths bounded above by the spectrum
        // (where it exceeds threshold) and below by the threshold line.
        // Walk the bins finding continuous "over" runs and emit one path
        // per run so disjoint loud regions don't visually connect.
        var i = 0
        while i < buckets {
            // skip bins that are not over
            while i < buckets && spectrumPoints[i].y >= thresholdPoints[i].y { i += 1 }
            guard i < buckets else { break }
            let runStart = i
            while i < buckets && spectrumPoints[i].y < thresholdPoints[i].y { i += 1 }
            let runEnd = i  // exclusive
            // Need at least 2 points to fill.
            guard runEnd - runStart >= 2 else { continue }

            var fill = Path()
            // Top edge: spectrum from runStart → runEnd-1
            fill.move(to: spectrumPoints[runStart])
            for j in (runStart + 1)..<runEnd {
                fill.addLine(to: spectrumPoints[j])
            }
            // Bottom edge: threshold from runEnd-1 → runStart
            for j in stride(from: runEnd - 1, through: runStart, by: -1) {
                fill.addLine(to: thresholdPoints[j])
            }
            fill.closeSubpath()

            // Amber gradient — strongest where the spectrum stands tallest
            // over the line. Anchored to the spectrum-region range so the
            // tint reads consistently across runs.
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(stops: [
                    .init(color: Color(red: 1.0, green: 0.55, blue: 0.15).opacity(a11yOpacity(0.65, reduceFactor: 1.4)), location: 0),
                    .init(color: Color(red: 1.0, green: 0.70, blue: 0.20).opacity(a11yOpacity(0.20, reduceFactor: 2.5)), location: 1)
                ]),
                startPoint: CGPoint(x: 0, y: topY),
                endPoint: CGPoint(x: 0, y: baselineY)
            )
            context.fill(fill, with: shading)
        }

        // Static threshold line — dashed, faint, drawn LAST so it sits on
        // top of the amber fill as a visible reference edge.
        let line = Self.smoothCurve(through: thresholdPoints)
        context.stroke(
            line,
            with: .color(Color(red: 1.0, green: 0.70, blue: 0.25).opacity(0.45)),
            style: StrokeStyle(
                lineWidth: 1.0,
                lineCap: .round,
                lineJoin: .round,
                dash: [4, 3]
            )
        )
    }

    /// Quadratic-through-midpoints smoothing — for each interior point the
    /// curve passes through the midpoint of (p_i, p_{i+1}) with p_i as the
    /// control point. The result is C¹ continuous, never overshoots the
    /// input samples, and turns a noisy polyline into a smooth silhouette.
    private static func smoothCurve(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        let firstMid = CGPoint(
            x: (points[0].x + points[1].x) / 2,
            y: (points[0].y + points[1].y) / 2
        )
        path.addLine(to: firstMid)
        for i in 1..<(points.count - 1) {
            let curr = points[i]
            let next = points[i + 1]
            let mid = CGPoint(x: (curr.x + next.x) / 2, y: (curr.y + next.y) / 2)
            path.addQuadCurve(to: mid, control: curr)
        }
        path.addLine(to: points.last!)
        return path
    }

    private func drawPreSpectrum(_ context: GraphicsContext, size: CGSize) {
        guard !preSpectrumBinsDB.isEmpty else { return }
        let baselineY = size.height
        let topY = size.height * (1 - spectrumHeightFraction)
        let buckets = preSpectrumBinsDB.count

        // Build smoothed silhouette points using the same quadratic-through-
        // midpoints helper as the post-EQ spectrum. Visually unified.
        var points: [CGPoint] = []
        points.reserveCapacity(buckets)
        for b in 0..<buckets {
            let x = size.width * CGFloat(b) / CGFloat(max(1, buckets - 1))
            let y = spectrumY(
                dbfs: Double(preSpectrumBinsDB[b]),
                baseline: baselineY, top: topY
            )
            points.append(CGPoint(x: x, y: y))
        }
        let topCurve = Self.smoothCurve(through: points)

        var fillPath = topCurve
        fillPath.addLine(to: CGPoint(x: size.width, y: baselineY))
        fillPath.addLine(to: CGPoint(x: 0, y: baselineY))
        fillPath.closeSubpath()

        // Cool desaturated blue-gray — sits BEHIND the violet post-EQ fill so
        // the user reads it as "input ghost." Opacity is much lower than the
        // post-EQ gradient so where the chain has energy (the bottom of the
        // post fill) the input layer is essentially invisible; near the
        // silhouette tip where post fades to translucent, the input ghost
        // peeks through and the eye reads them as two stacked layers.
        // Desaturated cool gray-blue — pushed toward neutral so the input
        // reads as the "ghost layer" rather than a competing colour. Where
        // the violet output sits on top, the saturation gap (violet vs.
        // muted gray) carries the figure/ground cue; where the input peeks
        // above the output silhouette, the brightened top stop + crisper
        // outline still make the input shape legible against the dark
        // background. Bottom opacity dropped from 0.55 → 0.40 so the violet
        // output unambiguously dominates in the dense base region.
        let preTop = Color(red: 0.72, green: 0.76, blue: 0.82).opacity(a11yOpacity(0.05, reduceFactor: 3.0))
        let preMid = Color(red: 0.55, green: 0.60, blue: 0.68).opacity(a11yOpacity(0.22, reduceFactor: 2.0))
        let preBottom = Color(red: 0.42, green: 0.48, blue: 0.56).opacity(a11yOpacity(0.40, reduceFactor: 1.5))
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [
                .init(color: preTop, location: 0),
                .init(color: preMid, location: 0.55),
                .init(color: preBottom, location: 1)
            ]),
            startPoint: CGPoint(x: 0, y: topY),
            endPoint: CGPoint(x: 0, y: baselineY)
        )
        context.fill(fillPath, with: shading)

        // Crisper top stroke than the fill alone — needed because the input
        // gradient is now more translucent, so the silhouette top edge
        // would otherwise lose definition where it sits on the dark canvas
        // background (i.e. where it stands above the violet output). Still
        // visibly lighter weight than the post-EQ outline so hierarchy is
        // preserved: output is solid white, input is dimmed white-blue.
        context.stroke(
            topCurve,
            with: .color(Color(red: 0.82, green: 0.86, blue: 0.94).opacity(0.55)),
            style: StrokeStyle(lineWidth: 1.0, lineCap: .round, lineJoin: .round)
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

    // MARK: - Spectrogram annotations

    /// Friendly plain-English labels for the y-axis frequency regions.
    /// Maps the audible spectrum into named bands so non-technical users
    /// can navigate by sensation ("treble", "bass") instead of Hz numbers.
    private static let frequencyRegions: [(label: String, hz: Double)] = [
        ("Bass",       70),
        ("Low mids",   300),
        ("Upper mids", 1500),
        ("Presence",   5000),
        ("Air",        12000),
    ]

    /// Right-edge plain-English region labels for the spectrogram. Each
    /// label is anchored at the centre of its band (in log frequency)
    /// inside the heatmap region. Light, tertiary-style so the heatmap
    /// stays the dominant visual.
    private func drawFrequencyRegionLabels(_ context: GraphicsContext, size: CGSize) {
        let baselineY = size.height
        let topY = size.height * (1 - spectrumHeightFraction)
        let axis = freqAxis
        for (label, hz) in Self.frequencyRegions {
            // Spectrogram maps low → bottom, high → top (matches drawSpectrogram).
            let frac = axis.frac(forHz: hz)
            let y = baselineY - CGFloat(frac) * (baselineY - topY)
            let text = Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.white.opacity(a11yOpacity(0.65, reduceFactor: 1.5)))
            // Right-aligned with a small inset.
            context.draw(text, at: CGPoint(x: size.width - 10, y: y), anchor: .trailing)
        }
    }

    /// Horizontal time-axis labels along the bottom of the spectrogram.
    /// Anchored "now" at the right edge (newest frame), with seconds-ago
    /// tick markers stepping leftward. Default cadence assumes ~20 frames
    /// per second of history (matches `spectrogramHistoryLength = 180` at
    /// 20 Hz throttle = 9 seconds visible).
    private func drawTimeAxis(_ context: GraphicsContext, size: CGSize) {
        guard spectrumHistory.count >= 2 else { return }
        let baselineY = size.height
        let frames = spectrumHistory.count
        // Total visible seconds = frames / publish-rate. We don't have the
        // exact publish-rate here, but `SpectrumAnalyzer.minDispatchInterval`
        // caps it at 20 Hz, so frames/20 is a reasonable estimate.
        let secondsVisible = Double(frames) / 20.0
        // Show "now" plus one tick every ~2 seconds back.
        let ticks: [Double] = [0, 2, 4, 6, 8].filter { $0 <= secondsVisible }
        for tickSeconds in ticks {
            let frac = tickSeconds / max(0.01, secondsVisible)  // 0 = newest (right), 1 = oldest (left)
            let x = size.width * (1.0 - CGFloat(frac))
            let label = tickSeconds == 0 ? "now" : "−\(Int(tickSeconds))s"
            let text = Text(label)
                .font(.caption2.weight(.medium))
                .foregroundColor(.white.opacity(a11yOpacity(0.55, reduceFactor: 1.7)))
            // Sit just below the heatmap region (above the freq-label row).
            context.draw(text, at: CGPoint(x: x, y: baselineY - 26), anchor: .center)

            // Subtle vertical tick mark.
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: baselineY - 14))
            tick.addLine(to: CGPoint(x: x, y: baselineY - 18))
            context.stroke(tick, with: .color(.white.opacity(0.35)), lineWidth: 1)
        }
    }

    /// Horizontal line across the spectrogram at the tinnitus notch
    /// frequency. Lets users see whether the audio has energy at their
    /// own tinnitus pitch — and how the notch processes it. Only drawn
    /// when the notch is enabled (otherwise the user hasn't claimed a
    /// pitch to compare against).
    private func drawNotchLine(_ context: GraphicsContext, size: CGSize) {
        guard let notch, notch.enabled else { return }
        let baselineY = size.height
        let topY = size.height * (1 - spectrumHeightFraction)
        let frac = freqAxis.frac(forHz: notch.frequencyHz)
        let y = baselineY - CGFloat(frac) * (baselineY - topY)
        var line = Path()
        line.move(to: CGPoint(x: 0, y: y))
        line.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(
            line,
            with: .color(.purple.opacity(0.75)),
            style: StrokeStyle(
                lineWidth: 1.25,
                lineCap: .round,
                lineJoin: .round,
                dash: [4, 3]
            )
        )
        // Right-edge label so the user knows what the line represents
        // without having to recall their notch setting.
        let labelHz = notch.frequencyHz >= 1000
            ? String(format: "tinnitus %.1f kHz", notch.frequencyHz / 1000)
            : "tinnitus \(Int(notch.frequencyHz)) Hz"
        let text = Text(labelHz)
            .font(.caption2.weight(.medium))
            .foregroundColor(.purple.opacity(0.95))
        context.draw(text, at: CGPoint(x: size.width - 10, y: y - 10), anchor: .trailing)
    }

    /// Persistence highlight: outlines frequency bins whose energy has
    /// stayed above a threshold for at least `persistenceMinFrames` of
    /// the visible history. A sustained tone shows as a horizontal band;
    /// transient sounds don't. Helpful for tinnitus tone-finding ("there's
    /// a steady tone here at this frequency") and for noticing whether
    /// noise exposure is continuous vs intermittent.
    private static let persistenceThresholdDBFS: Float = -55
    private static let persistenceMinFraction: Double = 0.7
    private func drawPersistence(_ context: GraphicsContext, size: CGSize) {
        guard spectrumHistory.count >= 10 else { return }
        let baselineY = size.height
        let topY = size.height * (1 - spectrumHeightFraction)
        let frames = spectrumHistory.count
        let bins = spectrumHistory.last?.count ?? 0
        guard bins > 0 else { return }
        let height = baselineY - topY
        let rowH = height / CGFloat(bins)

        // For each bin, count how many frames it exceeded the threshold.
        // Bins above `persistenceMinFraction` get an amber outline drawn
        // on top of the heatmap — a horizontal "this is sustained" stripe.
        var hotCounts = [Int](repeating: 0, count: bins)
        for column in spectrumHistory {
            for b in 0..<min(bins, column.count) {
                if column[b] > Self.persistenceThresholdDBFS { hotCounts[b] += 1 }
            }
        }
        let minHotFrames = Int(Double(frames) * Self.persistenceMinFraction)
        for b in 0..<bins where hotCounts[b] >= minHotFrames {
            let y = baselineY - CGFloat(b + 1) * rowH
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y + rowH / 2))
            line.addLine(to: CGPoint(x: size.width, y: y + rowH / 2))
            context.stroke(
                line,
                with: .color(Color(red: 1.0, green: 0.78, blue: 0.25).opacity(0.55)),
                style: StrokeStyle(lineWidth: 0.75, lineCap: .round)
            )
        }
    }

    /// Small color-scale legend in the top-right corner of the spectrogram.
    /// Most spectrograms ship without one; users without an audio-engineering
    /// background can't tell whether a colour represents −20 dBFS or −60 dBFS.
    private func drawColorLegend(_ context: GraphicsContext, size: CGSize) {
        let topY = size.height * (1 - spectrumHeightFraction)
        let legendWidth: CGFloat = 110
        let legendHeight: CGFloat = 8
        let pad: CGFloat = 12
        let legendX = size.width - legendWidth - pad
        let legendY = topY + pad

        // Gradient bar matching the heatmap palette.
        let stops: [Gradient.Stop] = [
            .init(color: Self.heatmapColor(forDB: -90), location: 0),
            .init(color: Self.heatmapColor(forDB: -70), location: 0.25),
            .init(color: Self.heatmapColor(forDB: -50), location: 0.5),
            .init(color: Self.heatmapColor(forDB: -35), location: 0.75),
            .init(color: Self.heatmapColor(forDB: -20), location: 1),
        ]
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: stops),
            startPoint: CGPoint(x: legendX, y: legendY),
            endPoint: CGPoint(x: legendX + legendWidth, y: legendY)
        )
        let bar = CGRect(x: legendX, y: legendY, width: legendWidth, height: legendHeight)
        context.fill(Path(roundedRect: bar, cornerRadius: 2), with: shading)
        context.stroke(
            Path(roundedRect: bar, cornerRadius: 2),
            with: .color(.white.opacity(0.35)),
            lineWidth: 0.5
        )

        // Endpoint labels.
        let quietText = Text("quiet")
            .font(.caption2)
            .foregroundColor(.white.opacity(0.75))
        let loudText = Text("loud")
            .font(.caption2)
            .foregroundColor(.white.opacity(0.85))
        context.draw(quietText, at: CGPoint(x: legendX, y: legendY + legendHeight + 8), anchor: .leading)
        context.draw(loudText, at: CGPoint(x: legendX + legendWidth, y: legendY + legendHeight + 8), anchor: .trailing)
    }

    // MARK: - Cursor readout

    /// Floating readout near the user's pointer showing what they're
    /// hovering over. Different content per visualisation mode — for the
    /// spectrogram it includes a time-ago estimate, for spectrum/bars it's
    /// just frequency + dB.
    @ViewBuilder
    private func cursorReadout(at point: CGPoint, in size: CGSize) -> some View {
        if let info = cursorInfo(at: point, in: size) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.primary)
                    .font(.callout.monospacedDigit().weight(.medium))
                if let secondary = info.secondary {
                    Text(secondary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
            )
            .allowsHitTesting(false)
            // Clamp the readout's position so it can't fall outside the
            // canvas — offset away from the pointer so it's not directly
            // under the cursor.
            .position(
                x: min(size.width - 70, max(70, point.x + 12)),
                y: min(size.height - 24, max(24, point.y - 14))
            )
            // Skip the fade when Reduce Motion is on. Callouts still
            // appear/disappear instantly; just no opacity animation.
            .transition(reduceMotion ? .identity : .opacity)
        }
    }

    private struct CursorInfo {
        let primary: String
        let secondary: String?
    }

    private func cursorInfo(at point: CGPoint, in size: CGSize) -> CursorInfo? {
        guard point.x >= 0, point.x <= size.width,
              point.y >= 0, point.y <= size.height else { return nil }
        let hz = freqForX(point.x, width: size.width)
        let hzLabel = hz >= 1000
            ? String(format: "%.2f kHz", hz / 1000)
            : String(format: "%.0f Hz", hz)

        let baselineY = size.height
        let topY = size.height * (1 - spectrumHeightFraction)

        switch vizMode {
        case .spectrum, .octaveBars:
            // dBFS — only meaningful inside the spectrum band.
            if point.y >= topY {
                let frac = (baselineY - point.y) / (baselineY - topY)
                let db = spectrumMinDB + Double(frac) * (spectrumMaxDB - spectrumMinDB)
                return CursorInfo(
                    primary: hzLabel,
                    secondary: String(format: "%.0f dBFS", db)
                )
            } else {
                // EQ region — show dB-gain only.
                let db = dbForY(point.y, height: size.height)
                return CursorInfo(
                    primary: hzLabel,
                    secondary: String(format: "%+.0f dB EQ", db)
                )
            }
        case .spectrogram:
            // Time-ago derived from the x-position.
            let frac = point.x / size.width
            let secondsAgo = (1.0 - Double(frac)) * (Double(spectrumHistory.count) / 20.0)
            let timeStr = secondsAgo < 0.25
                ? "now"
                : String(format: "%.1fs ago", secondsAgo)
            return CursorInfo(
                primary: hzLabel,
                secondary: timeStr
            )
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
        // Reserve a strip at the bottom for the semantic-group + tinnitus
        // labels drawn after the bars. Without this, group labels would
        // overdraw the brightest part of each bar's gradient and be
        // unreadable. Frequency tick labels share the same strip.
        let labelStripHeight: CGFloat = 50
        let baselineY = size.height - labelStripHeight
        let topY = size.height * (1 - spectrumHeightFraction)

        // Faint dBFS reference lines inside the bar region — give the eye
        // something to gauge bar heights against without reading the side
        // scale. These are the MAJOR ticks (every 10 dB); the dark overlay
        // pass below uses a denser 3 dB grid for the LED-segment look.
        let majorSteps = Array(stride(from: spectrumMinDB + 10, through: spectrumMaxDB, by: 10))
        let segmentSteps = Array(stride(from: spectrumMinDB + 3, through: spectrumMaxDB, by: 3))
        for refDB in majorSteps {
            let y = spectrumY(dbfs: refDB, baseline: baselineY, top: topY)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(
                line,
                with: .color(.white.opacity(0.18)),
                style: StrokeStyle(lineWidth: 0.5, dash: [3, 4])
            )
        }

        let bins = spectrumBinsDB.count
        let axis = freqAxis

        let barFactor = pow(2.0, 1.0 / 6.0)         // half-width of 1/3 octave
        let gap: CGFloat = 2

        // Cap color is uniform across all bars — sits at peak-hold height,
        // reads as "this is the recent maximum" regardless of which
        // semantic group the bar belongs to.
        let capColor = Color(red: 0.95, green: 0.98, blue: 1.0).opacity(0.85)

        // UNIFORM-STEP layout, sized to fit. Per-bar log positions caused
        // visible width variation (±1 px ≈ 3% on ~34 pt bars, noticeable
        // in dense rows). Uniform step + `floor` keeps every bar exactly
        // the same width AND guarantees the rightmost bar's right edge
        // stays inside the canvas — `round` previously accumulated drift
        // that pushed it off.
        //
        // Insets reserve space at each edge so the bars don't run into
        // the dB labels (drawn at x ≈ 16 by `drawDBLabels`) on the left
        // or the canvas's rounded corner on the right. The frequency
        // tick labels live at the bottom of the canvas, so they don't
        // affect horizontal bar layout.
        let leftInset: CGFloat = 36
        let rightInset: CGFloat = 12
        let usableWidth = size.width - leftInset - rightInset
        let visibleCenters = Self.thirdOctaveCenters.filter { $0 >= minHz && $0 <= maxHz }
        guard !visibleCenters.isEmpty, usableWidth > 0 else { return }
        let count = CGFloat(visibleCenters.count)
        let stepPx = floor((usableWidth - gap) / count)  // floor so total span ≤ usableWidth
        let barWidth = max(1, stepPx - gap)
        // Centre the row inside the usable width by absorbing leftover
        // pixels as a small symmetric inner inset on top of the left/
        // right reserved space.
        let firstX = leftInset + floor((usableWidth - (count * stepPx)) / 2)

        var barRects: [CGRect] = []
        barRects.reserveCapacity(visibleCenters.count)

        // Threshold y-positions in canvas coordinates. Computed per-bar
        // since A_weight varies with frequency. Cached out of the inner
        // colour loop to keep the per-bar work small.
        for (i, centerHz) in visibleCenters.enumerated() {
            let lowHz = centerHz / barFactor
            let highHz = centerHz * barFactor
            let lowFrac = axis.frac(forHz: lowHz, clamped: true)
            let highFrac = axis.frac(forHz: highHz, clamped: true)
            let lowBin = max(0, Int(Double(bins) * lowFrac))
            let highBin = min(bins - 1, Int(Double(bins) * highFrac))
            guard lowBin <= highBin else { continue }

            var peakDB: Float = -120
            for b in lowBin...highBin {
                if spectrumBinsDB[b] > peakDB { peakDB = spectrumBinsDB[b] }
            }

            let x0 = firstX + CGFloat(i) * stepPx
            let naturalTopYBar = spectrumY(dbfs: Double(peakDB), baseline: baselineY, top: topY)
            // 2 pt floor on bar height so silent bars stay visible.
            let minBarHeight: CGFloat = 2
            let topYBar = min(naturalTopYBar, baselineY - minBarHeight)
            let rect = CGRect(x: x0, y: topYBar, width: barWidth, height: baselineY - topYBar)
            barRects.append(rect)

            // === Per-section safety colouring ===
            // The bar visually splits into up to three vertical regions
            // based on where it crosses the safety threshold lines:
            //   • below threshold − headroom     → semantic group colour
            //   • [threshold − headroom, threshold)  → amber
            //   • at or above threshold           → red
            // Each section's gradient is anchored to the FULL spectrum
            // region (not the bar) so the LED top-translucent / bottom-
            // saturated look stays consistent regardless of bar height
            // or where the section sits within the bar.
            let group = Self.semanticGroup(for: centerHz, notch: notch)
            let thresholdDB = safetyThresholdDBFS(at: centerHz)
            let thresholdY = spectrumY(dbfs: thresholdDB, baseline: baselineY, top: topY)
            let approachingDB = thresholdDB - Self.safetyApproachingHeadroomDB
            let approachingY = spectrumY(dbfs: approachingDB, baseline: baselineY, top: topY)

            // Each section's y-range is bounded by the bar's actual
            // top/bottom, so sections that fall outside the bar's height
            // simply don't draw.
            func clamp(_ y: CGFloat) -> CGFloat { min(baselineY, max(topYBar, y)) }
            let exceedingTop = topYBar
            let exceedingBottom = clamp(thresholdY)
            let approachingTop = exceedingBottom
            let approachingBottom = clamp(approachingY)
            let safeTop = approachingBottom
            let safeBottom = baselineY

            func sectionShading(_ color: Color) -> GraphicsContext.Shading {
                .linearGradient(
                    Gradient(stops: [
                        .init(color: color.opacity(a11yOpacity(0.20, reduceFactor: 3.0)), location: 0),
                        .init(color: color.opacity(a11yOpacity(0.65, reduceFactor: 1.5)), location: 0.55),
                        .init(color: color.opacity(a11yOpacity(1.00, reduceFactor: 1.0)), location: 1)
                    ]),
                    startPoint: CGPoint(x: rect.midX, y: topY),
                    endPoint: CGPoint(x: rect.midX, y: baselineY)
                )
            }

            if exceedingBottom > exceedingTop {
                let secRect = CGRect(x: x0, y: exceedingTop, width: barWidth, height: exceedingBottom - exceedingTop)
                context.fill(Path(secRect), with: sectionShading(Self.safetyExceedingColor))
            }
            if approachingBottom > approachingTop {
                let secRect = CGRect(x: x0, y: approachingTop, width: barWidth, height: approachingBottom - approachingTop)
                context.fill(Path(secRect), with: sectionShading(Self.safetyApproachingColor))
            }
            if safeBottom > safeTop {
                let secRect = CGRect(x: x0, y: safeTop, width: barWidth, height: safeBottom - safeTop)
                context.fill(Path(secRect), with: sectionShading(group.color))
            }

            // Peak-hold cap at the bar's tip.
            if !spectrumPeakHoldDB.isEmpty {
                var peakHold: Float = -120
                for b in lowBin...highBin {
                    if spectrumPeakHoldDB[b] > peakHold { peakHold = spectrumPeakHoldDB[b] }
                }
                let capY = spectrumY(dbfs: Double(peakHold), baseline: baselineY, top: topY)
                let cap = CGRect(x: x0, y: capY - 1, width: barWidth, height: 1.5)
                context.fill(Path(cap), with: .color(capColor))
            }
        }

        // Segment dividers: dark horizontal slices through each bar at every
        // 3 dB step, giving the dense stacked-LED look of a hardware bar
        // meter — bright segments separated by thin dark gaps. Confined to
        // each bar's rect so the dividers don't spill into the dark
        // background between bars.
        for rect in barRects {
            for refDB in segmentSteps {
                let y = spectrumY(dbfs: refDB, baseline: baselineY, top: topY)
                guard y > rect.minY && y < rect.maxY else { continue }
                let slice = CGRect(x: rect.minX, y: y - 0.5, width: rect.width, height: 1)
                context.fill(Path(slice), with: .color(.black.opacity(0.75)))
            }
        }

        // Bottom label row: plain-English group names with a tiny color
        // swatch matching the bar gradient. Each label is anchored to
        // the left edge of the first bar in its group so the eye reads
        // the label as "this group starts here."
        drawSemanticGroupLabels(
            context, size: size,
            visibleCenters: visibleCenters,
            firstX: firstX,
            stepPx: stepPx
        )
    }

    // MARK: - Semantic group labelling (Bars mode)

    /// One named auditory region. The bar at any frequency in `lowHz...highHz`
    /// gets this group's `color` as its gradient hue, and the group label
    /// sits at the bottom of the canvas centered over the bars in this band.
    struct SemanticGroup {
        let id: String
        let label: String
        let lowHz: Double
        let highHz: Double
        let color: Color
    }

    /// Seven auditory regions covering 20 Hz–20 kHz, in order from low to
    /// high. Vocabulary matches the Speech EQ view sliders so the user
    /// learns one consistent set of names across the app.
    static let semanticGroups: [SemanticGroup] = [
        SemanticGroup(id: "subBass",   label: "Sub-bass",   lowHz: 20,    highHz: 60,    color: Color(red: 0.40, green: 0.40, blue: 0.85)),
        SemanticGroup(id: "bass",      label: "Bass",       lowHz: 60,    highHz: 250,   color: Color(red: 0.30, green: 0.55, blue: 0.92)),
        SemanticGroup(id: "lowMids",   label: "Low mids",   lowHz: 250,   highHz: 500,   color: Color(red: 0.20, green: 0.78, blue: 0.85)),
        SemanticGroup(id: "vocalBody", label: "Vocal body", lowHz: 500,   highHz: 1500,  color: Color(red: 0.25, green: 0.85, blue: 0.50)),
        SemanticGroup(id: "clarity",   label: "Clarity",    lowHz: 1500,  highHz: 4000,  color: Color(red: 0.60, green: 0.90, blue: 0.30)),
        SemanticGroup(id: "sibilance", label: "Sibilance",  lowHz: 4000,  highHz: 8000,  color: Color(red: 1.00, green: 0.78, blue: 0.25)),
        SemanticGroup(id: "air",       label: "Air",        lowHz: 8000,  highHz: 20001, color: Color(red: 0.62, green: 0.85, blue: 0.96)),
    ]

    /// Special "tinnitus pitch" group — only used when a profile's notch
    /// is enabled. Color is the same purple as the notch marker elsewhere
    /// in the app so the visual language is consistent. Width is ±1/6
    /// octave — matches one bar at the notch centre.
    static let tinnitusGroupColor = Color(red: 0.62, green: 0.40, blue: 0.85)
    static let tinnitusGroupLabel = "Tinnitus"

    // MARK: - Safety colouring (Bars mode)

    /// Headroom-in-dB below threshold at which we start tinting the bar
    /// amber. Smaller window = bar only goes amber right at the edge;
    /// larger = earlier warning. 6 dB matches "you're within one
    /// doubling of the limit" which is the right gut-feel for "you should
    /// be paying attention."
    static let safetyApproachingHeadroomDB: Double = 6
    /// Amber for bars approaching the safety threshold (within
    /// `safetyApproachingHeadroomDB` of it). Same hue as the spectrum
    /// view's safety overlay so the visual language stays consistent.
    static let safetyApproachingColor = Color(red: 1.0, green: 0.65, blue: 0.20)
    /// Red for bars at or above the safety threshold.
    static let safetyExceedingColor = Color(red: 1.0, green: 0.30, blue: 0.30)

    enum BarSafetyState {
        case safe        // comfortably below threshold
        case approaching // within headroom of threshold
        case exceeding   // at or above threshold
    }

    /// Classify a bar's peak energy against the per-frequency safety
    /// threshold curve. The threshold itself is driven by the user's
    /// profile `safetyCeilingDBA` + their `calibrationOffsetDBA` (see
    /// `safetyThresholdDBFS(at:)`), so this naturally tightens as the
    /// user's calibration value reflects louder playback.
    private func barSafetyState(forCenterHz hz: Double, peakDB: Float) -> BarSafetyState {
        let threshold = safetyThresholdDBFS(at: hz)
        let distance = Double(peakDB) - threshold
        if distance >= 0 {
            return .exceeding
        }
        if distance >= -Self.safetyApproachingHeadroomDB {
            return .approaching
        }
        return .safe
    }

    /// Look up the semantic group for a given bar's center frequency.
    /// When the active profile has an enabled notch and the bar sits at
    /// the notch pitch (±1/6 octave), returns a synthetic tinnitus group
    /// that overrides the natural semantic group. Otherwise returns the
    /// natural group; falls back to Air at the upper edge.
    static func semanticGroup(for hz: Double, notch: TinnitusNotch?) -> SemanticGroup {
        if let notch, notch.enabled {
            let factor = pow(2.0, 1.0 / 6.0)  // ±1/6 octave window
            let low = notch.frequencyHz / factor
            let high = notch.frequencyHz * factor
            if hz >= low && hz <= high {
                return SemanticGroup(
                    id: "tinnitus",
                    label: tinnitusGroupLabel,
                    lowHz: low,
                    highHz: high,
                    color: tinnitusGroupColor
                )
            }
        }
        for group in semanticGroups where hz >= group.lowHz && hz < group.highHz {
            return group
        }
        return semanticGroups.last!
    }

    private func drawSemanticGroupLabels(
        _ context: GraphicsContext,
        size: CGSize,
        visibleCenters: [Double],
        firstX: CGFloat,
        stepPx: CGFloat
    ) {
        // Place labels at the very bottom of the canvas. The frequency
        // tick labels still draw at y = size.height − 14; group labels
        // sit a row above them so both are readable without overlap.
        let labelY = size.height - 32
        let swatchSize: CGFloat = 8
        let axis = freqAxis

        for group in Self.semanticGroups {
            // Anchor the label to the LEFT EDGE of the first bar whose
            // centre falls in this group's range. Reads as "the group
            // starts here" rather than the older "group spans this
            // region" centred layout. Falls back to a log-space
            // projection if no bar centre lands in the group (e.g. the
            // axis was zoomed so this group has no visible bars).
            let startX: CGFloat
            if let firstIdx = visibleCenters.firstIndex(where: { $0 >= group.lowHz && $0 < group.highHz }) {
                startX = firstX + CGFloat(firstIdx) * stepPx
            } else {
                let frac = axis.frac(forHz: group.lowHz)
                startX = CGFloat(frac) * size.width
            }

            // Small color swatch + label, side by side.
            let labelText = Text(group.label)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.white.opacity(a11yOpacity(0.85, reduceFactor: 1.2)))
            let labelResolved = context.resolve(labelText)

            // Swatch (small rounded rect in the group hue) at the
            // first-bar's left edge, clamped to stay inside the canvas.
            let swatchRect = CGRect(
                x: max(2, startX),
                y: labelY - swatchSize / 2,
                width: swatchSize,
                height: swatchSize
            )
            context.fill(
                Path(roundedRect: swatchRect, cornerRadius: 1.5),
                with: .color(group.color.opacity(a11yOpacity(0.95, reduceFactor: 1.0)))
            )

            // Label, anchored to the right of the swatch.
            context.draw(
                labelResolved,
                at: CGPoint(x: swatchRect.maxX + 4, y: labelY),
                anchor: .leading
            )
        }

        // Tinnitus label, if the notch is enabled. Placed at the notch
        // pitch's x position to teach the user where their pitch sits
        // in the audio map.
        if let notch, notch.enabled {
            let frac = axis.frac(forHz: notch.frequencyHz)
            let x = max(20, min(size.width - 40, CGFloat(frac) * size.width))
            let labelY2 = size.height - 46  // a row above the other labels
            let labelText = Text(Self.tinnitusGroupLabel)
                .font(.caption2.weight(.semibold))
                .foregroundColor(Self.tinnitusGroupColor.opacity(a11yOpacity(0.95, reduceFactor: 1.05)))
            let swatchRect = CGRect(
                x: x - 28, y: labelY2 - swatchSize / 2,
                width: swatchSize, height: swatchSize
            )
            context.fill(
                Path(roundedRect: swatchRect, cornerRadius: 1.5),
                with: .color(Self.tinnitusGroupColor)
            )
            context.draw(
                labelText,
                at: CGPoint(x: swatchRect.maxX + 4, y: labelY2),
                anchor: .leading
            )
        }
    }

    /// ISO 1/3-octave center frequencies covering the 20 Hz – 20 kHz
    /// audible range. 31 bands total — full ISO standard.
    private static let thirdOctaveCenters: [Double] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200,
        250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000,
        2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000
    ]

    private func spectrumY(dbfs: Double, baseline: CGFloat, top: CGFloat) -> CGFloat {
        let clamped = max(spectrumMinDB, min(spectrumMaxDB, dbfs))
        let normalized = (clamped - spectrumMinDB) / (spectrumMaxDB - spectrumMinDB)
        return baseline - CGFloat(normalized) * (baseline - top)
    }

    private func drawFrequencyLabels(_ context: GraphicsContext, size: CGSize) {
        // `.caption` (scalable) rather than `.caption2` (smaller) so users
        // who bump Dynamic Type get readable axis labels. The monospaced
        // variant keeps the digits from jittering across redraws.
        // Safe-area: edge labels (those whose natural position is near a
        // canvas edge) are anchored to their respective EDGES rather than
        // their centres. That guarantees they sit inside the canvas frame
        // regardless of label width, Dynamic Type size, or the rounded
        // corner radius — which the previous center-clamp couldn't.
        let edgeInset: CGFloat = 18
        let edgeProximity: CGFloat = 36  // raw-x within this from an edge → use edge anchor
        for hz in labeledFrequencies {
            let rawX = xForFreq(hz, width: size.width)
            let label = formatHz(hz)
            let text = Text(label)
                .font(.caption.monospaced())
                .foregroundColor(.white.opacity(a11yOpacity(0.55, reduceFactor: 1.7)))
            let y = size.height - 14
            if rawX < edgeProximity {
                context.draw(text, at: CGPoint(x: edgeInset, y: y), anchor: .leading)
            } else if rawX > size.width - edgeProximity {
                context.draw(text, at: CGPoint(x: size.width - edgeInset, y: y), anchor: .trailing)
            } else {
                context.draw(text, at: CGPoint(x: rawX, y: y), anchor: .center)
            }
        }
    }

    private func drawDBLabels(_ context: GraphicsContext, size: CGSize) {
        // Safe-area: clamp each label's y so the topmost (+18) and bottom-
        // most (−18) stay inside the canvas frame instead of getting half-
        // cropped by the rounded-rect clip. 12pt vertical inset matches the
        // bottom frequency-label inset. Stride-by-6 plays cleanly with the
        // ±18 dB EQ range — labels read −18 / −12 / −6 / 0 / +6 / +12 / +18.
        let topSafe: CGFloat = 12
        let bottomSafe: CGFloat = 12
        for db in stride(from: minDB, through: maxDB, by: 6) {
            let rawY = yForDB(db, height: size.height)
            let y = max(topSafe, min(size.height - bottomSafe, rawY))
            let label = db > 0 ? "+\(Int(db))" : "\(Int(db))"
            let text = Text(label)
                .font(.caption.monospaced())
                .foregroundColor(.white.opacity(a11yOpacity(0.55, reduceFactor: 1.7)))
            context.draw(text, at: CGPoint(x: 16, y: y), anchor: .center)
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
        freqAxis.x(forHz: hz, width: width)
    }

    private func freqForX(_ x: CGFloat, width: CGFloat) -> Double {
        freqAxis.hz(forX: x, width: width)
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
        // 20k anchors the right edge of the axis. Without it the rightmost
        // label sat far inside the canvas with a big visual gap on the right.
        [50, 100, 500, 1000, 5000, 10000, 20000]
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

// MARK: - Live wrapper

/// Live-updating wrapper around `ParametricCanvasView`. Holds the
/// `@ObservedObject` references to one or two `SpectrumAnalyzer`s
/// directly so SwiftUI invalidates ONLY this subtree on each FFT
/// publish — not the entire `@EnvironmentObject` graph.
///
/// `AudioState` previously rebroadcast `spectrum.objectWillChange` upstream,
/// which combined with `audioState` being an `@EnvironmentObject` everywhere
/// meant a full-tree re-evaluation ~23 times per second. With this wrapper
/// the broadcast is cut and only views that explicitly observe an analyzer
/// (this one, plus future Meters / SafeListening views) pay the cost.
struct LiveParametricCanvas: View {
    @ObservedObject var spectrum: SpectrumAnalyzer
    /// Optional pre-EQ analyzer. When non-nil, observed by an inner view so
    /// outer redraws still fire only on the post-EQ analyzer's cadence.
    let preSpectrum: SpectrumAnalyzer?
    /// Pass `true` only in Spectrogram-capable views — the array is large
    /// (180 frames × 256 floats) so we skip the read when not needed.
    var includeHistory: Bool = false

    @Binding var bands: [EQBand]
    var shadowBands: [EQBand] = []
    var targetBands: [EQBand] = []
    var shadowTargetBands: [EQBand] = []
    var notch: TinnitusNotch? = nil
    var spectrumSampleRate: Double = 48_000
    var earColor: Color = .blue
    var shadowColor: Color = .red
    var vizMode: CanvasVizMode = .spectrum
    var readOnly: Bool = false
    @Binding var selectedBandID: UUID?
    var showInputSpectrum: Bool = true
    var showOutputSpectrum: Bool = true
    var showEQCurve: Bool = true
    var showAudiogramTarget: Bool = true
    var showResultCurve: Bool = false
    var showSafetyOverlay: Bool = true
    var showPeakCallouts: Bool = false
    // Spectrogram-mode layers — declared in the SAME order as
    // ParametricCanvasView so call sites can use trailing-arg syntax.
    var showNotchLine: Bool = true
    var showRegionLabels: Bool = true
    var showColorLegend: Bool = true
    var showTimeAxis: Bool = true
    var showPersistence: Bool = false
    var safetyCeilingDBA: Double = 85
    var calibrationOffsetDBA: Double = 100
    /// Forwarded EQ-curve gain range. Expert passes ±24 to match its clamp.
    var gainRangeDB: ClosedRange<Double> = -18...18

    /// Dynamic-EQ activity telemetry. When supplied (Expert canvas), an
    /// inner observer reads it at the monitor's ~15 Hz cadence and feeds the
    /// live per-feature bells into the canvas as a dashed overlay — scoped
    /// to that inner view so the rest of the canvas (and the host) doesn't
    /// re-render at meter rate.
    var dynamicsMonitor: DynamicActivityMonitor? = nil
    /// Which ear's dynamic activity to visualise (matches the displayed ear).
    var dynamicsEar: EQBandLookup.Ear = .left
    /// Enabled dynamic features on the displayed ear — their bells are the
    /// candidates for the overlay (filtered to currently-triggered ones).
    var dynamicsKinds: [DynamicFeatureKind] = []
    /// Master gate for the overlay (the Dynamics layer chip).
    var showDynamicsOverlay: Bool = false

    /// Tracks whether *this view instance* has currently subscribed to each
    /// analyzer. Prevents double-subscribe across re-renders and double-
    /// unsubscribe on teardown.
    @State private var subscribedToSpectrum: Bool = false
    @State private var subscribedToPreSpectrum: Bool = false
    @State private var subscribedToDynamics: Bool = false

    /// True when the overlay is wanted and wired — gates both the inner
    /// observer and the monitor subscription.
    private var dynamicsActive: Bool {
        showDynamicsOverlay && dynamicsMonitor != nil && !dynamicsKinds.isEmpty
    }

    var body: some View {
        // Only OBSERVE the pre-EQ analyzer when the input layer is on. If
        // the user has hidden the input chip we skip the @ObservedObject
        // attachment entirely, so this wrapper stops re-rendering at the
        // pre-EQ FFT cadence.
        Group {
            if dynamicsActive, let monitor = dynamicsMonitor {
                // Inner observer re-renders at the monitor's 15 Hz only —
                // the host (ExpertEQView) stays off that cadence.
                DynObserver(monitor: monitor) {
                    preWrappedCanvas(overlays: currentOverlays(from: monitor))
                }
            } else {
                preWrappedCanvas(overlays: [])
            }
        }
        // Lifecycle: drive both analyzers' subscriber counts from view
        // visibility (+ the Input chip for pre). When subscriberCount drops
        // to 0, the analyzer's FFT pipeline stops — `ingest` still does a
        // microsecond level pass for dose tracking, but the 20 Hz FFT +
        // smoothing + main-actor publish goes idle.
        .onAppear { syncSubscriptions() }
        .onDisappear { releaseSubscriptions() }
        .onChange(of: showInputSpectrum) { _, _ in syncSubscriptions() }
        .onChange(of: dynamicsActive) { _, _ in syncSubscriptions() }
    }

    @ViewBuilder
    private func preWrappedCanvas(overlays: [ParametricCanvasView.DynamicOverlay]) -> some View {
        if let preSpectrum, showInputSpectrum {
            PreObserver(preSpectrum: preSpectrum) { preBins in
                canvas(preBins: preBins, overlays: overlays)
            }
        } else {
            canvas(preBins: [], overlays: overlays)
        }
    }

    /// Build the current overlay set from the monitor, keeping only features
    /// whose live delta exceeds the rest threshold (0.1 dB) — so at rest the
    /// array is empty and the canvas draws nothing dynamic.
    private func currentOverlays(from monitor: DynamicActivityMonitor) -> [ParametricCanvasView.DynamicOverlay] {
        dynamicsKinds.compactMap { kind in
            let delta = monitor.gain(kind, dynamicsEar)
            guard abs(delta) >= 0.1 else { return nil }
            return ParametricCanvasView.DynamicOverlay(centerHz: kind.filterCenterHz, q: kind.filterQ, gainDB: delta)
        }
    }

    private func syncSubscriptions() {
        // Post-EQ analyzer: subscribed whenever this canvas is visible.
        if !subscribedToSpectrum {
            spectrum.subscribe()
            subscribedToSpectrum = true
        }
        // Pre-EQ analyzer: subscribed only when both visible AND the Input
        // chip is on. Two independent gates because pre-EQ has its own
        // upstream cost.
        // Dynamic-activity monitor: subscribed only while the overlay is
        // active so its 15 Hz poll loop idles otherwise.
        if let monitor = dynamicsMonitor {
            if dynamicsActive && !subscribedToDynamics {
                monitor.subscribe()
                subscribedToDynamics = true
            } else if !dynamicsActive && subscribedToDynamics {
                monitor.unsubscribe()
                subscribedToDynamics = false
            }
        }

        guard let preSpectrum else { return }
        if showInputSpectrum && !subscribedToPreSpectrum {
            preSpectrum.subscribe()
            subscribedToPreSpectrum = true
        } else if !showInputSpectrum && subscribedToPreSpectrum {
            preSpectrum.unsubscribe()
            subscribedToPreSpectrum = false
        }
    }

    private func releaseSubscriptions() {
        if subscribedToSpectrum {
            spectrum.unsubscribe()
            subscribedToSpectrum = false
        }
        if let preSpectrum, subscribedToPreSpectrum {
            preSpectrum.unsubscribe()
            subscribedToPreSpectrum = false
        }
        if let monitor = dynamicsMonitor, subscribedToDynamics {
            monitor.unsubscribe()
            subscribedToDynamics = false
        }
    }

    private func canvas(preBins: [Float], overlays: [ParametricCanvasView.DynamicOverlay] = []) -> some View {
        ParametricCanvasView(
            bands: $bands,
            shadowBands: shadowBands,
            targetBands: targetBands,
            shadowTargetBands: shadowTargetBands,
            notch: notch,
            spectrumBinsDB: spectrum.logSpectrumDB,
            spectrumPeakHoldDB: spectrum.logSpectrumPeakHoldDB,
            preSpectrumBinsDB: preBins,
            spectrumHistory: includeHistory ? spectrum.spectrogramHistory : [],
            spectrumSampleRate: spectrumSampleRate,
            earColor: earColor,
            shadowColor: shadowColor,
            vizMode: vizMode,
            readOnly: readOnly,
            selectedBandID: $selectedBandID,
            showInputSpectrum: showInputSpectrum,
            showOutputSpectrum: showOutputSpectrum,
            showEQCurve: showEQCurve,
            showAudiogramTarget: showAudiogramTarget,
            showResultCurve: showResultCurve,
            showSafetyOverlay: showSafetyOverlay,
            showPeakCallouts: showPeakCallouts,
            dynamicOverlays: overlays,
            showDynamicsOverlay: showDynamicsOverlay,
            showNotchLine: showNotchLine,
            showRegionLabels: showRegionLabels,
            showColorLegend: showColorLegend,
            showTimeAxis: showTimeAxis,
            showPersistence: showPersistence,
            safetyCeilingDBA: safetyCeilingDBA,
            calibrationOffsetDBA: calibrationOffsetDBA,
            gainRangeDB: gainRangeDB
        )
    }

    /// Inner view whose only job is to observe the pre-EQ analyzer. Scoped
    /// to this branch so the outer body doesn't re-render at 2× FFT rate.
    private struct PreObserver<Content: View>: View {
        @ObservedObject var preSpectrum: SpectrumAnalyzer
        let content: ([Float]) -> Content
        var body: some View { content(preSpectrum.logSpectrumDB) }
    }

    /// Inner view whose only job is to observe the dynamic-activity monitor.
    /// Scoped here so the ~15 Hz `gains` republishes re-render only the
    /// canvas subtree, not the Expert screen. The monitor only publishes
    /// when a value actually changes, so at rest this never re-renders.
    private struct DynObserver<Content: View>: View {
        @ObservedObject var monitor: DynamicActivityMonitor
        let content: () -> Content
        var body: some View { content() }
    }
}
