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
    /// The *other* ear's tinnitus notch, drawn as a dimmed marker so both
    /// ears' notches stay visible when per-ear notches differ. Only supplied
    /// when `separateNotch` is on (linked notches make this identical to
    /// `notch`). Never folded into the composite curve — the other ear's notch
    /// doesn't shape this ear's response; it's a reference marker only.
    var shadowNotch: TinnitusNotch? = nil
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

    /// Live Adaptive Correction gains (dB, one per filterbank band) —
    /// drawn as a dashed moving stroke via the filterbank's exact
    /// complex-response evaluator, so the overlay IS what the audio
    /// stage applies (phase4 §6.2). Empty = overlay off.
    var adaptiveGainsDB: [Double] = []

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
    /// How much of the canvas the spectrum underlay occupies from the
    /// baseline up. (40 → 50 in commit 10445ea when the Expert canvas grew
    /// to 450pt; 50 → 70 for 0.1.3 to give the iQualize-style live overlay
    /// enough vertical room to read as a proper background fill rather
    /// than a ribbon at the bottom.) The EQ curve, grid, and labels
    /// continue to draw across the full canvas.
    private let spectrumHeightFraction: CGFloat = 0.7

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
                    // Pre-EQ first so the post-EQ silhouette sits ON TOP
                    // of it — reads as "what's coming in" behind "what's
                    // leaving the chain". Reference-image hierarchy.
                    if showInputSpectrum { drawPreSpectrum(context, size: size) }
                    if showOutputSpectrum { drawSpectrum(context, size: size) }
                    if showSafetyOverlay { drawSafetyOverlay(context, size: size) }
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
                    // Live adaptive-correction response — same layer slot.
                    if !adaptiveGainsDB.isEmpty { drawAdaptiveOverlay(context, size: size) }
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
                    drawShadowNotchMarker(context, size: size)
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
                // Top-leading, click-through.
                curveLegend
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
                    .allowsHitTesting(false)
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
        .onChange(of: shadowNotch) { _, _ in recomputeCachedCurves() }
    }

    /// Resample active, shadow, and target curves into `cached*DB`. Cheap
    /// when bands are static (one pass on edit); free on subsequent frames.
    private func recomputeCachedCurves() {
        cachedCurveDB = sampledDB(for: bandsForCurve)
        cachedShadowDB = sampledDB(for: shadowBandsForCurve)
        cachedTargetDB = sampledDB(for: targetBands)
        // Result = what's heard: the EQ curve summed (in dB, via cascade) with
        // the audiogram correction. Computed per ear so an asymmetric audiogram
        // shows two Result lines even when the EQ is edited in lockstep.
        cachedResultDB = sampledDB(for: bandsForCurve + targetBands)
        cachedResultShadowDB = sampledDB(for: shadowBandsForCurve + shadowTargetBands)
        cachedTargetShadowDB = sampledDB(for: shadowTargetBands)
    }

    /// True when the two ears' curves differ audibly — drives whether the
    /// right-ear (shadow-hue) lines and the legend's Left/Right split are
    /// shown. Symmetric profiles draw one line per type and a simpler legend.
    /// Notches count: a per-ear notch on otherwise-identical ears is exactly
    /// the case where the second line carries information.
    private var earsAsymmetric: Bool {
        !bands.audiblyEquivalent(to: shadowBands)
            || !targetBands.audiblyEquivalent(to: shadowTargetBands)
            || effectiveNotchesDiffer
    }

    /// Whether the two ears' notches shape audio differently. Disabled and
    /// nil are the same thing (no contribution); two enabled notches compare
    /// by value (`TinnitusNotch` is UUID-free, so `==` is safe here, unlike
    /// freshly-synthesized `EQBand`s whose ids always differ).
    private var effectiveNotchesDiffer: Bool {
        let active = notch?.enabled == true ? notch : nil
        let shadow = shadowNotch?.enabled == true ? shadowNotch : nil
        return active != shadow
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
            if showAudiogramTarget { t.append((.correction, "Adjustment")) }
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
        // Same `asEQBand()` the audio path uses, so the drawn dip matches what
        // the listener hears — a finite parametric cut of `depthdB` at center.
        guard let notch, let notchBand = notch.asEQBand() else { return bands }
        return bands + [notchBand]
    }

    /// Shadow-ear equivalent of `bandsForCurve`. The audio applies each ear's
    /// notch to that ear, so the other-ear curve must fold its own notch in —
    /// otherwise the shadow line shows no dip even when that ear is notched
    /// (which is what happened: the Right curve never dipped in any EQ view).
    private var shadowBandsForCurve: [EQBand] {
        guard let shadowNotch, let notchBand = shadowNotch.asEQBand() else { return shadowBands }
        return shadowBands + [notchBand]
    }

    /// Vertical marker + label at the notch frequency. Drawn only while the
    /// notch is actually on — when it's off there's nothing in the curve to
    /// point at, so a stray marker just reads as phantom UI.
    /// The adaptive stage's current composite response (its six live band
    /// gains through the real filterbank math). Dashed, ear-tinted, under
    /// the static curves — the "drawn = heard" invariant on a moving
    /// target. Recomputes only when the telemetry publishes (≤ 15 Hz) and
    /// only while non-empty.
    private func drawAdaptiveOverlay(_ context: GraphicsContext, size: CGSize) {
        guard adaptiveGainsDB.count == AdaptiveFilterbank.bandCount else { return }
        let samples = 96
        var path = Path()
        let axis = freqAxis
        for i in 0..<samples {
            let frac = Double(i) / Double(samples - 1)
            let hz = axis.hz(forFrac: frac)
            let db = AdaptiveFilterbank.compositeMagnitudeDB(
                atHz: hz, gainsDB: adaptiveGainsDB, sampleRate: spectrumSampleRate)
            let pt = CGPoint(x: CGFloat(frac) * size.width, y: yForDB(db, height: size.height))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        context.stroke(
            path,
            with: .color(earColor.opacity(a11yOpacity(0.55, reduceFactor: 1.5))),
            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round, dash: [4, 3])
        )
    }

    private func drawNotchMarker(_ context: GraphicsContext, size: CGSize) {
        guard let notch, notch.enabled else { return }
        let x = xForFreq(notch.frequencyHz, width: size.width)
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(
            line,
            with: .color(.purple.opacity(0.5)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
        )
        let label = Text("notch \(Int(notch.frequencyHz)) Hz")
            .font(.caption2.monospaced())
            .foregroundColor(.purple.opacity(0.75))
        context.draw(label, at: CGPoint(x: x + 6, y: 14), anchor: .leading)
    }

    /// Dimmed marker for the *other* ear's tinnitus notch. Drawn under
    /// `drawNotchMarker` (thinner line, lower opacity, a second label row) so
    /// the active ear's notch reads as dominant while the other ear's pitch is
    /// still visible. Skipped when it would land on top of the active marker —
    /// two identical lines just read as one fuzzy line.
    private func drawShadowNotchMarker(_ context: GraphicsContext, size: CGSize) {
        guard let shadowNotch, shadowNotch.enabled else { return }
        if let notch, notch.enabled, abs(notch.frequencyHz - shadowNotch.frequencyHz) < 1 { return }
        let x = xForFreq(shadowNotch.frequencyHz, width: size.width)
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(
            line,
            with: .color(.purple.opacity(0.28)),
            style: StrokeStyle(lineWidth: 1, dash: [2, 4])
        )
        let label = Text("other ear \(Int(shadowNotch.frequencyHz)) Hz")
            .font(.caption2.monospaced())
            .foregroundColor(.purple.opacity(0.5))
        context.draw(label, at: CGPoint(x: x + 6, y: 30), anchor: .leading)
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

        // Faint peak-hold envelope above the silhouette — recent maxima at
        // each frequency. Rides with the Output layer.
        guard !spectrumPeakHoldDB.isEmpty else { return }
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
    /// below the tone's RMS; for broadband content the gap is larger as
    /// energy spreads further. Without this offset, bars never turn
    /// amber/red even when the dBA meter shows the user is well above
    /// their ceiling — the comparison would be apples-to-oranges.
    ///
    /// This was an empirical 12 dB fit against the old spectrum scale.
    /// `SpectrumAnalyzer` now coherent-gain-corrects that scale (bins read
    /// +1.76 dB, referencing (Σw)² rather than N² — see bug-audit #23), so
    /// the paired offset drops by the same 1.76 dB to keep the warn line
    /// exactly where it was tuned against Safe Listening's "Loud" state. The
    /// residual 10.24 dB is now purely the single-sided + broadband-spread
    /// gap, no longer the window's coherent gain.
    private static let safetyBinEnergyOffsetDB: Double = 10.24
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


    // MARK: - Cursor readout

    /// Floating readout near the user's pointer showing what they're
    /// hovering over: frequency plus dBFS (in the spectrum band) or
    /// dB gain (in the EQ region).
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
    }


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

    @Binding var bands: [EQBand]
    var shadowBands: [EQBand] = []
    var targetBands: [EQBand] = []
    var shadowTargetBands: [EQBand] = []
    var notch: TinnitusNotch? = nil
    var shadowNotch: TinnitusNotch? = nil
    var spectrumSampleRate: Double = 48_000
    var earColor: Color = .blue
    var shadowColor: Color = .red
    var readOnly: Bool = false
    @Binding var selectedBandID: UUID?
    var showInputSpectrum: Bool = true
    var showOutputSpectrum: Bool = true
    var showEQCurve: Bool = true
    var showAudiogramTarget: Bool = true
    var showResultCurve: Bool = false
    var showSafetyOverlay: Bool = true
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

    /// Adaptive Correction live telemetry (phase4 §6.2). When supplied and
    /// `showAdaptiveOverlay` is on, an inner observer feeds the displayed
    /// ear's live band gains into the canvas as the dashed moving-response
    /// stroke — scoped like the dynamics observer so only the canvas
    /// subtree re-renders at telemetry rate.
    var adaptiveMonitor: AdaptiveActivityMonitor? = nil
    var adaptiveEar: EQBandLookup.Ear = .left
    var showAdaptiveOverlay: Bool = false

    /// Tracks whether *this view instance* has currently subscribed to each
    /// analyzer. Prevents double-subscribe across re-renders and double-
    /// unsubscribe on teardown.
    @State private var subscribedToSpectrum: Bool = false
    @State private var subscribedToPreSpectrum: Bool = false
    @State private var subscribedToDynamics: Bool = false
    @State private var subscribedToAdaptive: Bool = false

    /// True when the overlay is wanted and wired — gates both the inner
    /// observer and the monitor subscription.
    private var dynamicsActive: Bool {
        showDynamicsOverlay && dynamicsMonitor != nil && !dynamicsKinds.isEmpty
    }

    private var adaptiveActive: Bool {
        showAdaptiveOverlay && adaptiveMonitor != nil
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
                    adaptiveWrapped(overlays: currentOverlays(from: monitor))
                }
            } else {
                adaptiveWrapped(overlays: [])
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
        .onChange(of: adaptiveActive) { _, _ in syncSubscriptions() }
    }

    @ViewBuilder
    private func adaptiveWrapped(overlays: [ParametricCanvasView.DynamicOverlay]) -> some View {
        if adaptiveActive, let monitor = adaptiveMonitor {
            AdaptiveObserver(monitor: monitor) {
                preWrappedCanvas(overlays: overlays, adaptiveGains: activeAdaptiveGains(from: monitor))
            }
        } else {
            preWrappedCanvas(overlays: overlays, adaptiveGains: [])
        }
    }

    /// The displayed ear's live gains — empty (overlay hidden) while the
    /// stage is idle at unity, so a flat zero line never clutters the view.
    private func activeAdaptiveGains(from monitor: AdaptiveActivityMonitor) -> [Double] {
        let gains = monitor.gains(for: adaptiveEar)
        return gains.contains { abs($0) >= 0.1 } ? gains : []
    }

    @ViewBuilder
    private func preWrappedCanvas(
        overlays: [ParametricCanvasView.DynamicOverlay],
        adaptiveGains: [Double]
    ) -> some View {
        if let preSpectrum, showInputSpectrum {
            PreObserver(preSpectrum: preSpectrum) { preBins in
                canvas(preBins: preBins, overlays: overlays, adaptiveGains: adaptiveGains)
            }
        } else {
            canvas(preBins: [], overlays: overlays, adaptiveGains: adaptiveGains)
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
        if let monitor = adaptiveMonitor {
            if adaptiveActive && !subscribedToAdaptive {
                monitor.subscribe()
                subscribedToAdaptive = true
            } else if !adaptiveActive && subscribedToAdaptive {
                monitor.unsubscribe()
                subscribedToAdaptive = false
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
        if let monitor = adaptiveMonitor, subscribedToAdaptive {
            monitor.unsubscribe()
            subscribedToAdaptive = false
        }
    }

    private func canvas(
        preBins: [Float],
        overlays: [ParametricCanvasView.DynamicOverlay] = [],
        adaptiveGains: [Double] = []
    ) -> some View {
        ParametricCanvasView(
            bands: $bands,
            shadowBands: shadowBands,
            targetBands: targetBands,
            shadowTargetBands: shadowTargetBands,
            notch: notch,
            shadowNotch: shadowNotch,
            spectrumBinsDB: spectrum.logSpectrumDB,
            spectrumPeakHoldDB: spectrum.logSpectrumPeakHoldDB,
            preSpectrumBinsDB: preBins,
            spectrumSampleRate: spectrumSampleRate,
            earColor: earColor,
            shadowColor: shadowColor,
            readOnly: readOnly,
            selectedBandID: $selectedBandID,
            showInputSpectrum: showInputSpectrum,
            showOutputSpectrum: showOutputSpectrum,
            showEQCurve: showEQCurve,
            showAudiogramTarget: showAudiogramTarget,
            showResultCurve: showResultCurve,
            showSafetyOverlay: showSafetyOverlay,
            dynamicOverlays: overlays,
            showDynamicsOverlay: showDynamicsOverlay,
            adaptiveGainsDB: adaptiveGains,
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

    /// Same scoping for the adaptive-correction telemetry.
    private struct AdaptiveObserver<Content: View>: View {
        @ObservedObject var monitor: AdaptiveActivityMonitor
        let content: () -> Content
        var body: some View { content() }
    }
}
