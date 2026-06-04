import SwiftUI

/// Skeuomorphic analog VU pair — needles driven by `StereoMonitor`'s
/// damped peak envelope. Pure decoration; the "real" meters live in
/// Safe Listening. Surfaced as an easter-egg toggle on MetersView.
struct AnalogVUMeterView: View {
    @ObservedObject var monitor: StereoMonitor
    /// Stack the L and R dials vertically rather than side-by-side. Set
    /// `true` when the host view is too narrow for two dials in a row
    /// (e.g. the right-hand `MonitorSidebar` at ~190pt usable width).
    /// The dial markings shrink to fit either layout naturally.
    var vertical: Bool = false

    var body: some View {
        if vertical {
            VStack(spacing: 10) {
                meter(label: "L", needle: monitor.leftNeedle)
                meter(label: "R", needle: monitor.rightNeedle)
            }
        } else {
            HStack(spacing: 24) {
                meter(label: "L", needle: monitor.leftNeedle)
                meter(label: "R", needle: monitor.rightNeedle)
            }
        }
    }

    private func meter(label: String, needle: Float) -> some View {
        VStack(spacing: 6) {
            ZStack {
                dialBackground
                dialScale
                needleView(position: CGFloat(needle))
                centerCap
            }
            .aspectRatio(1.4, contentMode: .fit)
            Text(label)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// Cream-coloured face plate with subtle inner shadow.
    private var dialBackground: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height * 1.4) / 2
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.95)
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.20, green: 0.18, blue: 0.14),
                                 Color(red: 0.10, green: 0.09, blue: 0.07)],
                        startPoint: .top, endPoint: .bottom
                    ))
                Circle()
                    .fill(RadialGradient(
                        colors: [Color(red: 0.96, green: 0.91, blue: 0.78),
                                 Color(red: 0.86, green: 0.78, blue: 0.62)],
                        center: .center,
                        startRadius: 0,
                        endRadius: r
                    ))
                    .frame(width: r * 2.1, height: r * 2.1)
                    .position(center)
                    .clipShape(Rectangle().path(in: CGRect(x: 0, y: 0, width: geo.size.width, height: geo.size.height * 0.95)))
            }
        }
    }

    /// Arc + tick marks + numerals (-20…+3 VU) + red zone at the top.
    private var dialScale: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.95)
            let r = min(geo.size.width, geo.size.height * 1.4) / 2 - 8
            let startAngle = Angle(degrees: 180 + 35)
            let endAngle = Angle(degrees: 360 - 35)
            let sweep = endAngle.radians - startAngle.radians

            ZStack {
                // Outer arc
                Path { p in
                    p.addArc(center: center, radius: r, startAngle: startAngle, endAngle: endAngle, clockwise: false)
                }
                .stroke(Color.black.opacity(0.75), lineWidth: 1.5)

                // Red zone (top quarter of dial)
                Path { p in
                    let zoneStart = startAngle + .radians(sweep * 0.78)
                    p.addArc(center: center, radius: r + 2, startAngle: zoneStart, endAngle: endAngle, clockwise: false)
                }
                .stroke(Color.red.opacity(0.85), lineWidth: 4)

                // Tick marks
                Canvas { ctx, _ in
                    for (i, label) in tickLabels.enumerated() {
                        let frac = Double(i) / Double(tickLabels.count - 1)
                        let angle = startAngle + .radians(sweep * frac)
                        let inner = CGPoint(
                            x: center.x + (r - 6) * cos(angle.radians),
                            y: center.y + (r - 6) * sin(angle.radians)
                        )
                        let outer = CGPoint(
                            x: center.x + r * cos(angle.radians),
                            y: center.y + r * sin(angle.radians)
                        )
                        var tick = Path()
                        tick.move(to: inner)
                        tick.addLine(to: outer)
                        let isMajor = !label.isEmpty
                        ctx.stroke(tick, with: .color(.black), lineWidth: isMajor ? 1.2 : 0.6)

                        if isMajor {
                            let labelPt = CGPoint(
                                x: center.x + (r - 16) * cos(angle.radians),
                                y: center.y + (r - 16) * sin(angle.radians)
                            )
                            ctx.draw(
                                Text(label).font(.caption2.monospaced()).foregroundColor(.black.opacity(0.75)),
                                at: labelPt,
                                anchor: .center
                            )
                        }
                    }
                }

                Text("VU")
                    .font(.caption2.weight(.semibold).italic())
                    .foregroundStyle(Color.black.opacity(0.6))
                    .position(x: center.x, y: center.y - r * 0.42)
            }
        }
    }

    /// Slim black needle that rotates from -∞ (left) to +3 VU (right).
    private func needleView(position: CGFloat) -> some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.95)
            let r = min(geo.size.width, geo.size.height * 1.4) / 2 - 8
            let startAngle = Angle(degrees: 180 + 35)
            let endAngle = Angle(degrees: 360 - 35)
            let frac = max(0, min(1.05, position))
            let sweep = endAngle.radians - startAngle.radians
            let angle = startAngle + .radians(sweep * Double(frac))

            let tipX = center.x + (r - 4) * cos(angle.radians)
            let tipY = center.y + (r - 4) * sin(angle.radians)
            let baseX = center.x + 6 * cos(angle.radians + .pi)
            let baseY = center.y + 6 * sin(angle.radians + .pi)

            Path { path in
                path.move(to: CGPoint(x: baseX, y: baseY))
                path.addLine(to: CGPoint(x: tipX, y: tipY))
            }
            .stroke(Color(red: 0.15, green: 0.05, blue: 0.05), lineWidth: 1.5)
        }
    }

    /// Brass-coloured pivot cap at the dial origin.
    private var centerCap: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.95)
            Circle()
                .fill(RadialGradient(
                    colors: [Color(red: 0.95, green: 0.82, blue: 0.45),
                             Color(red: 0.55, green: 0.40, blue: 0.18)],
                    center: .center, startRadius: 0, endRadius: 7
                ))
                .frame(width: 12, height: 12)
                .position(center)
        }
    }

    /// Position 0…1.05 corresponds to dBFS values via StereoMonitor.vuPosition.
    /// The labels here mirror that: -40 dBFS at the far left, 0 dBFS at the peg,
    /// with the red zone covering the last ~3 dBFS of headroom.
    private let tickLabels: [String] = [
        "-40", "", "-30", "", "-20", "", "-15", "", "-10", "", "-6", "-3", "0"
    ]
}
