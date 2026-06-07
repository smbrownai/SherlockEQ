import SwiftUI

/// Stereo XY phase scope. Plots (L, R) sample pairs rotated 45° so that
/// in-phase mono content reads as a vertical line, anti-phase as a
/// horizontal line, and wide stereo as a fat ellipse.
///
/// Each sample is drawn at low alpha so heavily-occupied regions
/// brighten naturally — feels like a CRT trace without needing a
/// proper phosphor decay buffer.
struct VectorscopeView: View {
    @ObservedObject var monitor: StereoMonitor

    var body: some View {
        Canvas { context, size in
            drawBackground(context, size: size)
            drawAxes(context, size: size)
            drawTrace(context, size: size)
            drawLabels(context, size: size)
        }
        .aspectRatio(1, contentMode: .fit)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.92))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Purely visual surface — there's no actionable state for VO
        // users to read or adjust, and the trace shape doesn't have a
        // useful one-sentence summary. Hide rather than emit a
        // misleading element. The numeric channel levels are already
        // exposed by DigitalLRMeter / PopoverLevelStrip.
        .accessibilityHidden(true)
    }

    private func drawBackground(_ ctx: GraphicsContext, size: CGSize) {
        // Subtle scope-tinted bloom in the centre — sets the CRT mood
        // before any signal lands.
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let bloomRect = CGRect(
            x: center.x - size.width * 0.45,
            y: center.y - size.height * 0.45,
            width: size.width * 0.9, height: size.height * 0.9
        )
        ctx.fill(
            Path(ellipseIn: bloomRect),
            with: .radialGradient(
                Gradient(colors: [
                    Color(red: 0.10, green: 0.45, blue: 0.20).opacity(0.35),
                    .clear
                ]),
                center: center,
                startRadius: 0,
                endRadius: size.width * 0.45
            )
        )
    }

    private func drawAxes(_ ctx: GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - 6
        let axisColor = GraphicsContext.Shading.color(.white.opacity(0.18))

        // Outer circle
        let circleRect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2, height: radius * 2
        )
        ctx.stroke(
            Path(ellipseIn: circleRect),
            with: axisColor,
            lineWidth: 0.75
        )

        // Diagonal axes (mono / anti-phase guides). +/- 45° lines.
        let diag = radius * cos(.pi / 4)
        var diagPath = Path()
        diagPath.move(to: CGPoint(x: center.x - diag, y: center.y - diag))
        diagPath.addLine(to: CGPoint(x: center.x + diag, y: center.y + diag))
        diagPath.move(to: CGPoint(x: center.x - diag, y: center.y + diag))
        diagPath.addLine(to: CGPoint(x: center.x + diag, y: center.y - diag))
        ctx.stroke(diagPath, with: axisColor, lineWidth: 0.5)

        // Cross-hair
        var cross = Path()
        cross.move(to: CGPoint(x: center.x, y: center.y - radius))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        cross.move(to: CGPoint(x: center.x - radius, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        ctx.stroke(cross, with: axisColor, lineWidth: 0.5)
    }

    private func drawTrace(_ ctx: GraphicsContext, size: CGSize) {
        let samples = monitor.scopeSamples
        guard !samples.isEmpty else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let scale = min(size.width, size.height) / 2 - 6

        // Each sample renders as a tiny filled circle so the trace looks
        // like a CRT phosphor rather than a connected line. Alpha is low
        // so density encodes "where the signal lives".
        let dotSize: CGFloat = 1.6
        var path = Path()
        for s in samples {
            // 45° rotation: x' = (l - r) / √2, y' = -(l + r) / √2
            // (negative y to put in-phase content vertically upward).
            let x = (CGFloat(s.l) - CGFloat(s.r)) / sqrt(2)
            let y = -(CGFloat(s.l) + CGFloat(s.r)) / sqrt(2)
            let px = center.x + x * scale
            let py = center.y + y * scale
            path.addEllipse(in: CGRect(
                x: px - dotSize / 2, y: py - dotSize / 2,
                width: dotSize, height: dotSize
            ))
        }
        ctx.fill(path, with: .color(Color(red: 0.45, green: 1.0, blue: 0.55).opacity(0.55)))
    }

    private func drawLabels(_ ctx: GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - 6
        let labelFont = Font.caption2.monospaced()
        let muted = Color.white.opacity(0.35)

        let labels: [(String, CGPoint)] = [
            ("M",  CGPoint(x: center.x, y: center.y - radius - 2)),  // mono (in-phase) up
            ("S",  CGPoint(x: center.x - radius - 8, y: center.y)),  // side / left
            ("+L", CGPoint(x: center.x + 4 - radius * cos(.pi/4), y: center.y - radius * sin(.pi/4))),
            ("+R", CGPoint(x: center.x - 4 + radius * cos(.pi/4), y: center.y - radius * sin(.pi/4))),
        ]
        for (text, pt) in labels {
            ctx.draw(Text(text).font(labelFont).foregroundColor(muted), at: pt, anchor: .center)
        }
    }
}
