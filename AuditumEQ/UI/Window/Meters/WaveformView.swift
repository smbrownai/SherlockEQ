import SwiftUI

/// Two-channel oscilloscope. L on the top half, R on the bottom,
/// each a freshly-drawn time-domain trace of `StereoMonitor.scopeSamples`.
/// Pure visual treat — not tied to any diagnostic. The trigger is a
/// simple zero-cross on L so the wave appears to stand still during
/// steady-state material.
struct WaveformView: View {
    @ObservedObject var monitor: StereoMonitor
    var earColor: Color
    var rightColor: Color

    var body: some View {
        Canvas { ctx, size in
            drawBackground(ctx, size: size)
            drawGrid(ctx, size: size)
            drawTrace(ctx, size: size)
        }
        .aspectRatio(2.4, contentMode: .fit)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.92))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func drawBackground(_ ctx: GraphicsContext, size: CGSize) {
        // Subtle green CRT haze fading from centre.
        let r = max(size.width, size.height)
        ctx.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(colors: [
                    Color(red: 0.06, green: 0.20, blue: 0.10).opacity(0.55),
                    .black
                ]),
                center: CGPoint(x: size.width / 2, y: size.height / 2),
                startRadius: 0,
                endRadius: r * 0.6
            )
        )
    }

    private func drawGrid(_ ctx: GraphicsContext, size: CGSize) {
        let grid = GraphicsContext.Shading.color(.white.opacity(0.10))
        let midline = GraphicsContext.Shading.color(.white.opacity(0.22))
        let splitY = size.height / 2

        // Centre divider
        var split = Path()
        split.move(to: CGPoint(x: 0, y: splitY))
        split.addLine(to: CGPoint(x: size.width, y: splitY))
        ctx.stroke(split, with: midline, lineWidth: 0.75)

        // Per-channel zero baselines
        let topZero = splitY / 2
        let bottomZero = splitY + splitY / 2
        for y in [topZero, bottomZero] {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: grid, lineWidth: 0.5)
        }

        // Vertical ticks
        let columns = 8
        for i in 0...columns {
            let x = size.width * CGFloat(i) / CGFloat(columns)
            var p = Path()
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: grid, lineWidth: 0.4)
        }
    }

    private func drawTrace(_ ctx: GraphicsContext, size: CGSize) {
        let samples = monitor.scopeSamples
        guard samples.count > 4 else { return }

        let trigger = positiveZeroCrossIndex(in: samples)
        let visibleStart = trigger
        let visibleEnd = min(samples.count, trigger + Self.visibleSamples)
        let visible = samples[visibleStart..<visibleEnd]
        guard !visible.isEmpty else { return }

        let topMid = size.height / 4
        let bottomMid = size.height * 3 / 4
        let amp = size.height / 4 - 4   // vertical range per channel

        let n = visible.count
        var leftPath = Path()
        var rightPath = Path()
        for (i, pair) in visible.enumerated() {
            let x = size.width * CGFloat(i) / CGFloat(n - 1)
            let ly = topMid - CGFloat(pair.l) * amp
            let ry = bottomMid - CGFloat(pair.r) * amp
            if i == 0 {
                leftPath.move(to: CGPoint(x: x, y: ly))
                rightPath.move(to: CGPoint(x: x, y: ry))
            } else {
                leftPath.addLine(to: CGPoint(x: x, y: ly))
                rightPath.addLine(to: CGPoint(x: x, y: ry))
            }
        }
        ctx.stroke(leftPath, with: .color(earColor.opacity(0.95)),
                   style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        ctx.stroke(rightPath, with: .color(rightColor.opacity(0.95)),
                   style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))

        // Channel labels
        ctx.draw(Text("L").font(.caption2.monospaced()).foregroundColor(earColor.opacity(0.6)),
                 at: CGPoint(x: 12, y: 14), anchor: .leading)
        ctx.draw(Text("R").font(.caption2.monospaced()).foregroundColor(rightColor.opacity(0.6)),
                 at: CGPoint(x: 12, y: size.height / 2 + 14), anchor: .leading)
    }

    /// Returns the first index where L crosses zero going positive, or
    /// 0 if none is found in the first half of the buffer (so the trace
    /// still draws — just unanchored — on heavily-transient material).
    private func positiveZeroCrossIndex(in samples: [StereoMonitor.SamplePair]) -> Int {
        let limit = min(samples.count / 2, 128)
        for i in 1..<limit {
            if samples[i - 1].l <= 0 && samples[i].l > 0 {
                return i
            }
        }
        return 0
    }

    /// Number of samples to draw across the canvas width. Less than the
    /// full scopeSampleCount so the trigger has room to shift left.
    private static let visibleSamples: Int = 384
}
