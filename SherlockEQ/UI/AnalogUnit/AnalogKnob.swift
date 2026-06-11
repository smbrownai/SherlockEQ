import SwiftUI
import AppKit

/// Shared palette for the Analog Control Unit. Warm metal + amber, tuned
/// to read like a 1970s hi-fi front panel rather than modern UI chrome.
enum AnalogTheme {
    static let faceTop    = Color(red: 0.18, green: 0.19, blue: 0.20)
    static let faceBottom = Color(red: 0.09, green: 0.095, blue: 0.10)
    static let recess     = Color(red: 0.06, green: 0.065, blue: 0.07)
    static let engrave    = Color(red: 0.74, green: 0.73, blue: 0.69)   // soft engraved gray
    static let engraveDim = Color(red: 0.52, green: 0.51, blue: 0.47)
    static let amber      = Color(red: 0.89, green: 0.70, blue: 0.28)   // warm highlight / pointer
    static let cream      = Color(red: 0.93, green: 0.90, blue: 0.82)
    static let hairline   = Color.white.opacity(0.06)

    static let silver = LinearGradient(
        colors: [
            Color(red: 0.91, green: 0.91, blue: 0.92),
            Color(red: 0.74, green: 0.75, blue: 0.77),
            Color(red: 0.55, green: 0.56, blue: 0.58),
            Color(red: 0.40, green: 0.41, blue: 0.43),
        ],
        startPoint: .top, endPoint: .bottom
    )
    static let rim = LinearGradient(
        colors: [Color.white.opacity(0.55), Color.black.opacity(0.55)],
        startPoint: .top, endPoint: .bottom
    )

    /// Outer brushed cylinder of a knob (the knurled skirt).
    static let skirt = LinearGradient(
        colors: [Color(white: 0.84), Color(white: 0.58), Color(white: 0.40)],
        startPoint: .top, endPoint: .bottom
    )

    /// Spun-aluminium top face: fine alternating light/dark spokes.
    static let machinedFace = AngularGradient(gradient: Gradient(stops: machinedStops), center: .center)
    private static let machinedStops: [Gradient.Stop] = {
        var stops: [Gradient.Stop] = []
        let n = 24
        for i in 0...n {
            stops.append(.init(color: Color(white: i % 2 == 0 ? 0.90 : 0.66),
                               location: Double(i) / Double(n)))
        }
        return stops
    }()

    /// Raised metal push-button cap.
    static let buttonRaised = LinearGradient(
        colors: [Color(white: 0.88), Color(white: 0.62), Color(white: 0.46)],
        startPoint: .top, endPoint: .bottom
    )
    /// Depressed / engaged push-button cap (darker, inverted sheen).
    static let buttonPressed = LinearGradient(
        colors: [Color(white: 0.30), Color(white: 0.44)],
        startPoint: .top, endPoint: .bottom
    )
}

/// A reusable vintage rotary knob. Visuals are pure SwiftUI; pointer
/// drag + scroll-wheel are handled by a thin AppKit overlay so they don't
/// fight SwiftUI's gesture system; keyboard and VoiceOver live on the
/// SwiftUI wrapper.
///
/// The knob is a *view over* a `Double` binding — it owns no audio state.
/// Double-click resets to `defaultValue`. Values are quantized to `step`
/// so a continuous drag doesn't spam the underlying setter (the EQ/balance
/// setters persist the whole profile on every change).
struct AnalogKnob: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    /// Quantization for drag / scroll / keyboard. e.g. 0.5 dB, 0.02 balance.
    var step: Double = 0.5
    /// Optional neutral mark drawn on the dial (e.g. 0 dB center detent).
    var detentValue: Double? = nil
    /// On-faceplate numeric readout. Retained in code (and still used for
    /// the spoken value); hidden on the dial unless `showReadout` is true,
    /// since a printed dB number isn't very "analog".
    let formatter: (Double) -> String
    /// Spoken VoiceOver value, e.g. "plus 3 decibels".
    var accessibilityValue: (Double) -> String
    /// Show the numeric dB readout under the knob. Off by default.
    var showReadout: Bool = false
    /// Dial diameter. Default fits the standard row; larger for the hero
    /// VOLUME knob.
    var size: CGFloat = 66
    /// Double-click resets to `defaultValue`. Off for controls with no
    /// meaningful default (e.g. system volume).
    var resettable: Bool = true

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    private var detentFraction: Double? {
        guard let d = detentValue else { return nil }
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return nil }
        return min(1, max(0, (d - range.lowerBound) / span))
    }

    var body: some View {
        VStack(spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .default))
                .tracking(1.6)
                .foregroundStyle(AnalogTheme.engrave)
                .shadow(color: .black.opacity(0.7), radius: 0, y: -0.5)

            ZStack {
                KnobDial(fraction: fraction, detentFraction: detentFraction, size: size)
                    .allowsHitTesting(false)
                KnobInteractor(value: $value, range: range, step: step,
                               defaultValue: defaultValue, resettable: resettable)
            }
            .frame(width: size, height: size)

            if showReadout {
                Text(formatter(value))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AnalogTheme.amber)
                    .lineLimit(1)
                    .frame(minWidth: 56)
            }
        }
        .focusable(true)
        .focusEffectDisabled()   // no gold focus ring — keep keyboard/VoiceOver
        .onKeyPress(.upArrow)    { adjust(by: step);  return .handled }
        .onKeyPress(.rightArrow) { adjust(by: step);  return .handled }
        .onKeyPress(.downArrow)  { adjust(by: -step); return .handled }
        .onKeyPress(.leftArrow)  { adjust(by: -step); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(accessibilityValue(value)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(by: step)
            case .decrement: adjust(by: -step)
            @unknown default: break
            }
        }
    }

    private func adjust(by delta: Double) {
        let clamped = min(max(value + delta, range.lowerBound), range.upperBound)
        let stepped = step > 0 ? (clamped / step).rounded() * step : clamped
        value = stepped == 0 ? 0 : stepped
    }
}

// MARK: - Dial visuals

private struct KnobDial: View {
    var fraction: Double
    var detentFraction: Double?
    var size: CGFloat = 66

    private var dial: CGFloat { size }
    private var bodySize: CGFloat { size * 0.76 }
    private let tickCount = 11

    /// −135° (min) … +135° (max), clockwise from 12 o'clock.
    private func angle(_ f: Double) -> Angle { .degrees(-135 + f * 270) }

    var body: some View {
        ZStack {
            faceplateScale
            knob
        }
        .frame(width: dial, height: dial)
    }

    /// Engraved scale ticks + neutral detent on the faceplate around the knob.
    private var faceplateScale: some View {
        ZStack {
            ForEach(0..<tickCount, id: \.self) { i in
                let f = Double(i) / Double(tickCount - 1)
                let end = i == 0 || i == tickCount - 1
                Capsule()
                    .fill(Color.white.opacity(end ? 0.42 : 0.18))
                    .frame(width: 1.4, height: end ? 7 : 4)
                    .frame(width: dial, height: dial, alignment: .top)
                    .rotationEffect(angle(f))
            }
            if let d = detentFraction {
                Capsule()
                    .fill(AnalogTheme.amber)
                    .frame(width: 2.2, height: 8)
                    .frame(width: dial, height: dial, alignment: .top)
                    .rotationEffect(angle(d))
            }
        }
    }

    /// The physical knob: brushed skirt + knurled grip + machined top
    /// face with concentric rings, plus an engraved pointer.
    private var knob: some View {
        ZStack {
            // Contact shadow in the faceplate.
            Circle()
                .fill(Color.black.opacity(0.55))
                .frame(width: bodySize + 3, height: bodySize + 3)
                .blur(radius: 4)
                .offset(y: 2.5)

            // Knurled brushed skirt + bevel.
            Circle()
                .fill(AnalogTheme.skirt)
                .frame(width: bodySize, height: bodySize)
                .overlay(Knurling().frame(width: bodySize, height: bodySize))
                .overlay(Circle().strokeBorder(AnalogTheme.rim, lineWidth: 1.4))
                .overlay(
                    Circle()
                        .strokeBorder(Color.black.opacity(0.35), lineWidth: 1)
                        .frame(width: bodySize * 0.74, height: bodySize * 0.74)
                )

            // Spun-metal top face with concentric machined rings.
            Circle()
                .fill(AnalogTheme.machinedFace)
                .frame(width: bodySize * 0.70, height: bodySize * 0.70)
                .overlay(
                    ZStack {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                            .frame(width: bodySize * 0.54, height: bodySize * 0.54)
                        Circle()
                            .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
                            .frame(width: bodySize * 0.36, height: bodySize * 0.36)
                    }
                )
                .overlay(
                    Ellipse()
                        .fill(Color.white.opacity(0.40))
                        .frame(width: bodySize * 0.40, height: bodySize * 0.16)
                        .offset(x: -bodySize * 0.10, y: -bodySize * 0.18)
                        .blur(radius: 2)
                )

            // Engraved pointer: dark groove with a light edge highlight.
            Capsule()
                .fill(Color(white: 0.12))
                .frame(width: 2.6, height: bodySize * 0.36)
                .overlay(
                    Capsule()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 0.8, height: bodySize * 0.36)
                        .offset(x: -0.9)
                )
                .frame(width: bodySize, height: bodySize, alignment: .top)
                .padding(.top, 4)
                .rotationEffect(angle(fraction))
                .frame(width: dial, height: dial)
        }
        .frame(width: dial, height: dial)
    }
}

/// Fine radial flutes around a knob's skirt — the machined grip.
private struct Knurling: View {
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let rOuter = size.width / 2 - 0.5
            let rInner = rOuter - 4
            let n = 56
            for i in 0..<n {
                let a = Double(i) / Double(n) * 2 * .pi
                var path = Path()
                path.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * rInner,
                                      y: c.y + CGFloat(sin(a)) * rInner))
                path.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * rOuter,
                                         y: c.y + CGFloat(sin(a)) * rOuter))
                ctx.stroke(path, with: .color(.black.opacity(0.22)), lineWidth: 0.7)
            }
        }
        .clipShape(Circle())
    }
}

// MARK: - AppKit pointer + scroll layer

/// Transparent overlay that turns vertical drag and scroll-wheel into
/// value changes, and double-click into a reset. Kept in AppKit so it
/// composes cleanly with SwiftUI focus/keyboard above and the SwiftUI
/// dial below (which has hit-testing disabled).
private struct KnobInteractor: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let defaultValue: Double
    var resettable: Bool = true
    var sensitivity: CGFloat = 180   // pixels of drag for the full range

    func makeNSView(context: Context) -> KnobNSView {
        let v = KnobNSView()
        configure(v)
        return v
    }

    func updateNSView(_ v: KnobNSView, context: Context) { configure(v) }

    private func configure(_ v: KnobNSView) {
        v.range = range
        v.step = step
        v.defaultValue = defaultValue
        v.resettable = resettable
        v.sensitivity = sensitivity
        v.valueProvider = { value }
        v.commit = { newValue in
            if value != newValue { value = newValue }
        }
    }

    final class KnobNSView: NSView {
        var valueProvider: () -> Double = { 0 }
        var commit: (Double) -> Void = { _ in }
        var range: ClosedRange<Double> = 0...1
        var step: Double = 0.01
        var defaultValue: Double = 0
        var resettable: Bool = true
        var sensitivity: CGFloat = 180

        private var anchorValue: Double = 0
        private var anchorY: CGFloat = 0

        // Don't steal key focus — SwiftUI's `.focusable` owns the keyboard.
        override var acceptsFirstResponder: Bool { false }
        override var isFlipped: Bool { false }
        // The window is movable by its background; without this, a transparent
        // view answers "yes" to `mouseDownCanMoveWindow` and AppKit drags the
        // window instead of letting us turn the knob. Say no here so drags on
        // a knob turn the knob; drags on the bare faceplate still move it.
        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeUpDown)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 {
                if resettable { commitClamped(defaultValue) }
                return
            }
            anchorValue = valueProvider()
            anchorY = event.locationInWindow.y
        }

        override func mouseDragged(with event: NSEvent) {
            let dy = event.locationInWindow.y - anchorY        // up is positive
            let span = range.upperBound - range.lowerBound
            commitClamped(anchorValue + Double(dy / sensitivity) * span)
        }

        override func scrollWheel(with event: NSEvent) {
            let span = range.upperBound - range.lowerBound
            commitClamped(valueProvider() + Double(event.scrollingDeltaY) * (span / 1500))
        }

        private func commitClamped(_ raw: Double) {
            let clamped = min(max(raw, range.lowerBound), range.upperBound)
            let stepped = step > 0 ? (clamped / step).rounded() * step : clamped
            let normalized = stepped == 0 ? 0 : stepped
            let threshold = step > 0 ? step / 2 : 1e-9
            if abs(normalized - valueProvider()) >= threshold {
                commit(normalized)
            }
        }
    }
}
