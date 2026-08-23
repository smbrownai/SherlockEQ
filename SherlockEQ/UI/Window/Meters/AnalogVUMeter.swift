import SwiftUI
import QuartzCore

/// Classic-style analog VU meter. Displays average program loudness
/// using proper IEC ballistics (~300 ms rise to 0 VU for a steady
/// 1 kHz sine) and a configurable 0 VU reference. Not a peak meter
/// and not a Dorrough-style combined peak/loudness display.
///
/// Visual identity: cream face, black hairline arc and tick marks,
/// slim dark needle pivoting below the dial, restrained red overscale
/// band above 0 VU. Identity preserved in dark mode — only the
/// surrounding bezel adapts.
///
/// Drives needle motion from `StereoMonitor`'s raw per-tick RMS via a
/// critically-damped second-order integrator per channel. Time-delta-
/// aware, so motion is consistent across 60 / 120 Hz refresh rates and
/// across missed frames (e.g. background → foreground transitions).
struct AnalogVUMeter: View {

    /// What kind of meter to display. The underlying data is the same
    /// in every case — `StereoMonitor` taps post-EQ stereo output, so
    /// the left channel already is the left-ear-processed signal and
    /// the right channel is the right-ear-processed signal. Layout and
    /// labels are what differ; the needle is always black ink so the
    /// instrument reads as an instrument rather than as a piece of the
    /// surrounding app's per-ear colour vocabulary.
    enum Mode: Equatable {
        /// Single dial. RMS power summed across channels so a centred
        /// mono source reads the same as on either channel alone.
        case mono
        /// Two dials labelled "LEFT CHANNEL" / "RIGHT CHANNEL".
        case stereo
    }

    /// Subscribes to the monitor's 60 Hz RMS pulse specifically, not to the
    /// monitor as a whole — this meter integrates its own ballistics from that
    /// pulse and doesn't read the peaks at all.
    @ObservedObject private var rms: StereoMonitor.RMSClock
    var mode: Mode = .stereo
    var calibration: VUCalibration = .standardDigital()
    /// Stack dials vertically instead of side-by-side. For narrow
    /// hosts where two dials wouldn't fit at a readable size.
    var vertical: Bool = false
    /// Numeric VU readout under each dial.
    var showReadout: Bool = false
    /// Calibration caption under the whole component ("0 VU = …").
    var showCalibrationLabel: Bool = false

    @State private var box = BallisticsBox()

    /// Written out because the memberwise init can't derive `rms` from
    /// `monitor`. Call sites are unchanged — they still pass the monitor.
    init(
        monitor: StereoMonitor,
        mode: Mode = .stereo,
        calibration: VUCalibration = .standardDigital(),
        vertical: Bool = false,
        showReadout: Bool = false,
        showCalibrationLabel: Bool = false
    ) {
        self._rms = ObservedObject(wrappedValue: monitor.rms)
        self.mode = mode
        self.calibration = calibration
        self.vertical = vertical
        self.showReadout = showReadout
        self.showCalibrationLabel = showCalibrationLabel
    }

    /// Per-channel ballistic state + last-tick timestamp. Stored in a
    /// reference type so the view body can integrate inline without
    /// tripping SwiftUI's "Modifying state during view update"
    /// warning. The reference itself never changes; only its fields.
    private final class BallisticsBox {
        var left = VUBallisticsState()
        var right = VUBallisticsState()
        var lastTime: TimeInterval = 0
    }

    var body: some View {
        // No TimelineView — the monitor's `RMSClock` republishes leftRMS/
        // rightRMS on every 60 Hz tick, which drives our re-render. We compute a
        // real wall-clock dt from CACurrentMediaTime so the integrator
        // is robust to dropped frames / display refresh variation.
        let _ = updateBallistics()
        return VStack(spacing: 6) {
            meterContent
            if showCalibrationLabel {
                Text(calibration.captionLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(Text("Calibration: \(calibration.captionLabel)"))
            }
        }
        .onDisappear {
            // Cold start the next time we appear, so a stale needle
            // value doesn't briefly show up before the audio thread
            // catches up.
            box.left.reset()
            box.right.reset()
            box.lastTime = 0
        }
    }

    private func updateBallistics() {
        let now = CACurrentMediaTime()
        let dt = box.lastTime > 0 ? (now - box.lastTime) : (1.0 / 60.0)
        box.lastTime = now
        let ref = calibration.referenceDBFS
        switch mode {
        case .mono:
            let l = Double(rms.leftRMS)
            let r = Double(rms.rightRMS)
            let summed = sqrt(l * l + r * r)
            box.left.update(rms: summed, referenceDBFS: ref, dt: dt)
        case .stereo:
            box.left.update(rms: Double(rms.leftRMS), referenceDBFS: ref, dt: dt)
            box.right.update(rms: Double(rms.rightRMS), referenceDBFS: ref, dt: dt)
        }
    }

    @ViewBuilder private var meterContent: some View {
        switch mode {
        case .mono:
            singleMeter(vu: box.left.vu, label: nil)
        case .stereo:
            let left = singleMeter(vu: box.left.vu, label: "LEFT CHANNEL")
            let right = singleMeter(vu: box.right.vu, label: "RIGHT CHANNEL")
            if vertical {
                VStack(spacing: 10) { left; right }
            } else {
                HStack(spacing: 14) { left; right }
            }
        }
    }

    @ViewBuilder
    private func singleMeter(vu: Double, label: String?) -> some View {
        VStack(spacing: 4) {
            VUMeterFace(vu: vu, needleColor: needleInk)
                .aspectRatio(1.6, contentMode: .fit)
                .accessibilityLabel(Text(accessibilityDescription(label: label, vu: vu)))
            if let label = label {
                Text(label)
                    .font(.caption2.weight(.semibold).monospaced())
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            if showReadout {
                Text(readoutString(vu))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Needle ink — always black, regardless of app accent or per-ear
    /// colours. The meter should read as an instrument, not as a piece
    /// of the surrounding UI palette.
    private var needleInk: Color { Color(red: 0.06, green: 0.05, blue: 0.04) }

    private func readoutString(_ vu: Double) -> String {
        if vu <= VUBallisticsState.floorVU + 0.5 { return "−∞ VU" }
        if vu >= 0 { return String(format: "+%.1f VU", vu) }
        return String(format: "%.1f VU", vu)
    }

    private func accessibilityDescription(label: String?, vu: Double) -> String {
        let lead = label.map { "\($0) channel " } ?? ""
        return "\(lead)VU meter: \(readoutString(vu)). \(calibration.captionLabel)."
    }
}

// MARK: - Dial face

/// Stateless dial-face renderer. Caller passes the current VU; we
/// draw the face, scale, "VU" label and needle. Canvas-based so the
/// hairline ticks stay crisp at any size and so we can hand-tune the
/// label fonts to match the dial size.
private struct VUMeterFace: View {
    let vu: Double
    let needleColor: Color
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            draw(ctx: &ctx, size: size)
        }
        .background(bezelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(bezelStroke, lineWidth: 0.5)
        )
    }

    // The bezel is the only thing that adapts to colour scheme — the
    // cream face stays cream in dark mode so the meter keeps its
    // classic identity, and the bezel deepens to fit the surrounding
    // window chrome.
    private var bezelBackground: LinearGradient {
        let colors: [Color] = colorScheme == .dark
            ? [Color(red: 0.13, green: 0.11, blue: 0.09),
               Color(red: 0.07, green: 0.06, blue: 0.05)]
            : [Color(red: 0.24, green: 0.21, blue: 0.18),
               Color(red: 0.15, green: 0.13, blue: 0.11)]
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private var bezelStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.35)
    }

    // MARK: drawing

    private func draw(ctx: inout GraphicsContext, size: CGSize) {
        // Inset for the cream face inside the bezel. Small but
        // noticeable — gives the face a "set into" look without the
        // need for fake screws or chrome.
        let inset: CGFloat = 5
        let faceRect = CGRect(
            x: inset, y: inset,
            width: size.width - 2 * inset,
            height: size.height - 2 * inset
        )
        guard faceRect.width > 4, faceRect.height > 4 else { return }

        // Cream face. Very subtle top-to-bottom gradient for depth —
        // explicit decision not to add fake scratches, vignettes, or
        // grime. A trustworthy instrument, not a relic.
        let creamTop = Color(red: 0.97, green: 0.93, blue: 0.85)
        let creamBot = Color(red: 0.91, green: 0.86, blue: 0.75)
        let facePath = Path(roundedRect: faceRect, cornerRadius: 3)
        ctx.fill(
            facePath,
            with: .linearGradient(
                Gradient(colors: [creamTop, creamBot]),
                startPoint: CGPoint(x: faceRect.midX, y: faceRect.minY),
                endPoint: CGPoint(x: faceRect.midX, y: faceRect.maxY)
            )
        )

        // Pivot sits below the face — emulating a moving-coil meter
        // whose arc radius is much larger than the visible window.
        // Numbers are tuned for an aspect-ratio-1.6 face.
        let pivot = CGPoint(x: faceRect.midX, y: faceRect.maxY + faceRect.height * 0.25)
        let radius = faceRect.height * 0.95
        let startAngleDeg = 220.0   // far left = −20 VU
        let endAngleDeg   = 320.0   // far right = +3 VU
        let sweepDeg = endAngleDeg - startAngleDeg

        // Scale fonts and tick lengths proportionally to face height,
        // clamped so a very small face stays readable and a very
        // large one doesn't get cartoonish.
        let scale = max(0.6, min(1.6, faceRect.height / 120.0))
        let majorTickLen = 11 * scale
        let zeroTickLen  = 14 * scale
        let labelInset   = 22 * scale

        // Ink colours. Warm-black for clarity on cream without the
        // harshness of pure #000.
        let ink = Color(red: 0.10, green: 0.08, blue: 0.06)
        let inkSoft = Color(red: 0.18, green: 0.14, blue: 0.10).opacity(0.85)
        let red = Color(red: 0.74, green: 0.10, blue: 0.08)

        // Main arc. Hairline weight — should feel like silkscreened
        // print, not a drawn-on line.
        var arcPath = Path()
        arcPath.addArc(
            center: pivot,
            radius: radius,
            startAngle: .degrees(startAngleDeg),
            endAngle: .degrees(endAngleDeg),
            clockwise: false
        )
        ctx.stroke(arcPath, with: .color(ink), lineWidth: 1.0)

        // Red overscale band, just outside the arc.
        let zoneStart = startAngleDeg + sweepDeg * VUScale.zeroFrac
        var zonePath = Path()
        zonePath.addArc(
            center: pivot,
            radius: radius + 3 * scale,
            startAngle: .degrees(zoneStart),
            endAngle: .degrees(endAngleDeg),
            clockwise: false
        )
        ctx.stroke(zonePath, with: .color(red), lineWidth: 2.2 * scale)

        // Tick marks + labels.
        for tick in VUScale.ticks {
            let angleDeg = startAngleDeg + sweepDeg * tick.frac
            let rad = angleDeg * .pi / 180.0
            let isZero = tick.vu == 0
            let isPositive = tick.vu > 0
            let length = isZero ? zeroTickLen : majorTickLen

            let inner = CGPoint(
                x: pivot.x + (radius - length) * cos(rad),
                y: pivot.y + (radius - length) * sin(rad)
            )
            let outer = CGPoint(
                x: pivot.x + radius * cos(rad),
                y: pivot.y + radius * sin(rad)
            )
            var t = Path()
            t.move(to: inner)
            t.addLine(to: outer)
            let strokeWidth: CGFloat = isZero ? 1.8 : 1.1
            let strokeColor = isPositive ? red : (isZero ? ink : inkSoft)
            ctx.stroke(t, with: .color(strokeColor), lineWidth: strokeWidth)

            // Numeric label.
            let lpRadius = radius - labelInset
            let lp = CGPoint(
                x: pivot.x + lpRadius * cos(rad),
                y: pivot.y + lpRadius * sin(rad)
            )
            let labelText: String
            if isPositive { labelText = "+" + tick.label }
            else if tick.vu < 0 { labelText = "−" + tick.label }
            else { labelText = tick.label }
            let fontSize = isZero ? 12 * scale : 10 * scale
            let weight: Font.Weight = isZero ? .bold : .semibold
            let labelColor = isPositive ? red : ink
            ctx.draw(
                Text(labelText)
                    .font(.system(size: fontSize, weight: weight, design: .default).monospacedDigit())
                    .foregroundColor(labelColor),
                at: lp,
                anchor: .center
            )
        }

        // Classic italic "VU" label, positioned between the scale and
        // the pivot — the place every moving-coil meter has had it
        // since the late 1930s.
        let vuLabelPoint = CGPoint(x: pivot.x, y: pivot.y - radius * 0.42)
        ctx.draw(
            Text("VU")
                .font(.system(size: 13 * scale, weight: .semibold, design: .serif).italic())
                .foregroundColor(ink.opacity(0.7)),
            at: vuLabelPoint,
            anchor: .center
        )

        // Needle.
        let needleFrac = VUScale.frac(forVU: vu)
        let clamped = max(0, min(1.06, needleFrac))
        let needleAngleDeg = startAngleDeg + sweepDeg * clamped
        let needleRad = needleAngleDeg * .pi / 180.0
        let tip = CGPoint(
            x: pivot.x + (radius + 1) * cos(needleRad),
            y: pivot.y + (radius + 1) * sin(needleRad)
        )
        let needleBaseLen: CGFloat = 8 * scale
        let base = CGPoint(
            x: pivot.x - needleBaseLen * cos(needleRad),
            y: pivot.y - needleBaseLen * sin(needleRad)
        )
        var needlePath = Path()
        needlePath.move(to: base)
        needlePath.addLine(to: tip)
        let needleStyle = StrokeStyle(lineWidth: 1.4 * scale, lineCap: .round)
        ctx.stroke(needlePath, with: .color(needleColor), style: needleStyle)

        // Small dark pivot cap. No chrome, no radial gradient — just
        // a disk at the rotation point so the eye reads the needle as
        // pinned, not floating.
        let capSize = 7 * scale
        let capRect = CGRect(
            x: pivot.x - capSize / 2,
            y: pivot.y - capSize / 2,
            width: capSize, height: capSize
        )
        ctx.fill(Path(ellipseIn: capRect), with: .color(ink.opacity(0.9)))
    }
}
