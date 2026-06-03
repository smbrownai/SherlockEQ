import SwiftUI

/// Menu-bar icon for AuditumEQ. Tints based on the session safe-listening dose
/// (spec §5.4): default → amber at 80% → red at 100%. The macOS menu bar
/// renders SF Symbols monochrome by default, so `foregroundStyle` is what
/// actually drives the colour.
struct MenuBarIcon: View {
    @ObservedObject var audioState: AudioState

    var body: some View {
        // macOS menu bar treats SF Symbols as template images by default,
        // ignoring foreground colour. .symbolRenderingMode(.palette) + an
        // explicit foreground gives the system a colour to render with.
        // If that's still flattened on this OS version, an overlaid dot
        // provides a guaranteed-visible indicator.
        Image(systemName: symbol)
            .symbolRenderingMode(.palette)
            .foregroundStyle(tint)
            .overlay(alignment: .topTrailing) {
                if dotVisible {
                    Circle()
                        .fill(tint)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -2)
                }
            }
    }

    private var dotVisible: Bool {
        audioState.safeListening.didCrossAmberToday ||
        audioState.safeListening.didCrossRedToday ||
        dose >= 0.8
    }

    private var dose: Double { audioState.safeListening.sessionDose }

    private var tint: Color {
        if audioState.safeListening.didCrossRedToday || dose >= 1.0 {
            return .red
        }
        if audioState.safeListening.didCrossAmberToday || dose >= 0.8 {
            return .orange
        }
        return .primary
    }

    private var symbol: String { "waveform.and.magnifyingglass" }
}
