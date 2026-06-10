import SwiftUI

/// Liquid Glass adoption helpers, gated on macOS 26 (Tahoe). The app
/// deploys to macOS 14.6+, so every Tahoe-only surface API gets an
/// availability guard here with the pre-26 styling preserved as the
/// fallback — call sites stay one-modifier clean and Sonoma renders
/// exactly what it rendered before the glass adoption.
extension View {

    /// Soft scroll-edge fade where content passes under the toolbar.
    /// No-op below macOS 26 (Sonoma has no glass toolbar to fade under).
    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

    /// Glass surface for chip / banner-shaped controls. On Tahoe this is
    /// Liquid Glass (optionally tinted); on Sonoma it falls back to the
    /// flat fill + stroke the control used before glass adoption.
    /// The system glass degrades to a solid material automatically under
    /// Reduce Transparency / Increase Contrast, so no extra guard needed.
    @ViewBuilder
    func glassChipSurface(
        tint: Color?,
        cornerRadius: CGFloat = 7,
        fallbackFill: Color,
        fallbackStroke: Color
    ) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                tint.map { Glass.regular.tint($0) } ?? .regular,
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            self
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(fallbackFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(fallbackStroke, lineWidth: 1)
                )
        }
    }
}
