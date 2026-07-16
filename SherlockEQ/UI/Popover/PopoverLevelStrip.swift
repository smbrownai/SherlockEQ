import SwiftUI

/// Thin live L/R level strip for the popover. Answers the at-a-glance
/// question "is anything actually reaching the output?" without
/// requiring the user to open the main window. Not a calibrated VU,
/// not a peak meter with hold — just a confident pulse that says
/// "audio is flowing, here's roughly how loud."
///
/// Colour zones are derived from the same dBA thresholds as Safe
/// Listening's level meter via the user's playback calibration, so the
/// popover and the main window agree on what "loud" means.
struct PopoverLevelStrip: View {
    @ObservedObject var monitor: StereoMonitor
    /// SPL calibration in dB (0 dBFS → this many dB SPL at the listener).
    /// Same value as the sidebar/Safe Listening uses, so colour
    /// boundaries land at consistent dBFS positions.
    let calibrationOffsetDBA: Double
    /// False when nothing is playing — the meters are replaced by a plain
    /// "Waiting for audio" rather than sitting empty.
    var isReceivingAudio: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            Text("Output level")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)

            // Two empty tracks look like unset sliders rather than idle
            // meters, so when nothing is playing say so in words instead.
            if isReceivingAudio {
                VStack(spacing: 3) {
                    bar(label: "L", peak: monitor.leftPeak)
                    bar(label: "R", peak: monitor.rightPeak)
                }
            } else {
                Text("Waiting for audio")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Subscribe ties the StereoMonitor's 60 Hz display loop on
        // while the popover is visible; unsubscribe lets it idle when
        // the popover closes. Ref-counted so this composes with the
        // sidebar's subscription on the main window.
        .onAppear { monitor.subscribe() }
        .onDisappear { monitor.unsubscribe() }
    }

    /// One horizontal bar. Channel label sits to the left so the row
    /// stays legible without forcing a peak-readout number — the
    /// popover is deliberately not a metering surface.
    ///
    /// The fill is composed of three FIXED-POSITION zone sections
    /// (green / yellow / red), each growing only up to where the peak
    /// currently reaches. The whole bar never recolours when the peak
    /// crosses a threshold — only the lengths of each section change.
    /// That matches what the sidebar's `DigitalLRMeter` does and lines
    /// up with how a hardware meter's LED ladder reads at a glance.
    @ViewBuilder
    private func bar(label: String, peak: Float) -> some View {
        let peakDBVal = peakDB(peak)
        let zone: String = {
            let yellowBoundary = 70 - calibrationOffsetDBA
            let redBoundary = 85 - calibrationOffsetDBA
            if peakDBVal >= redBoundary { return "very loud" }
            if peakDBVal >= yellowBoundary { return "loud" }
            return "moderate"
        }()
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10, alignment: .leading)
            GeometryReader { geo in
                let W = geo.size.width
                let peakX = W * fillFraction(forDB: peakDBVal)
                let yellowX = W * fillFraction(forDB: 70 - calibrationOffsetDBA)
                let redX    = W * fillFraction(forDB: 85 - calibrationOffsetDBA)

                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)

                    // Green: 0 → min(peak, yellow boundary).
                    let greenW = min(peakX, yellowX)
                    if greenW > 0 {
                        Rectangle().fill(Self.greenColor)
                            .frame(width: greenW)
                    }
                    // Yellow: yellow boundary → min(peak, red boundary).
                    if peakX > yellowX {
                        let yellowW = min(peakX, redX) - yellowX
                        if yellowW > 0 {
                            Rectangle().fill(Self.yellowColor)
                                .frame(width: yellowW)
                                .offset(x: yellowX)
                        }
                    }
                    // Red: red boundary → peak.
                    if peakX > redX {
                        Rectangle().fill(Self.redColor)
                            .frame(width: peakX - redX)
                            .offset(x: redX)
                    }

                    // Zone-boundary tick marks — non-color encoding
                    // so colorblind users can locate the moderate /
                    // loud / very-loud thresholds without relying on
                    // the green / yellow / red transition.
                    Rectangle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 1)
                        .offset(x: yellowX)
                    Rectangle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 1)
                        .offset(x: redX)
                }
                .clipShape(Capsule())
            }
            .frame(height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) channel peak level")
        .accessibilityValue(String(format: "%.0f dBFS, %@", peakDBVal, zone))
    }

    private func peakDB(_ peak: Float) -> Double {
        peak > 1e-5 ? 20 * log10(Double(peak)) : -60.0
    }

    /// Map a dBFS value to a 0…1 horizontal fraction across the bar.
    /// Fixed 60 dB dynamic range matches the sidebar's scale, so the
    /// same audio reads at the same proportional position in both.
    private func fillFraction(forDB db: Double) -> CGFloat {
        CGFloat(max(0, min(1, (db + 60) / 60)))
    }

    // Slightly muted palette versus the sidebar's saturated zones —
    // the popover row is a glance surface, not a calibration display.
    // Same hues as Safe Listening + the dose meter, just dialled back
    // so the row reads as ambient rather than alarming.
    private static let greenColor  = Color.green.opacity(0.80)
    private static let yellowColor = Color.yellow.opacity(0.85)
    private static let redColor    = Color.red.opacity(0.85)
}
