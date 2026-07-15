import SwiftUI

/// Layer-visibility chips for the parametric canvas.
///
/// Each chip independently toggles one canvas overlay.
///
/// Accessibility:
/// - Chip state uses BOTH fill+color and a checkmark glyph — never color
///   alone. Colorblind users + system "Differentiate Without Color" get
///   the same signal.
/// - All labels scale with `Dynamic Type`. Default body-size, not caption.
/// - Each chip is a `Button` with explicit `accessibilityLabel` and
///   `accessibilityValue("on"/"off")` so VoiceOver reads "Output, on,
///   toggle button".
struct CanvasLayerChipStrip: View {
    @Binding var showInputSpectrum: Bool
    @Binding var showOutputSpectrum: Bool
    @Binding var showEQCurve: Bool
    @Binding var showAudiogramTarget: Bool
    /// The combined "Result" curve — correction + EQ, i.e. what's actually
    /// heard. The default-visible hero line when an audiogram exists.
    @Binding var showResultCurve: Bool
    @Binding var showSafetyOverlay: Bool
    /// Live dynamic-feature bells overlay (Listening Comfort features).
    @Binding var showDynamics: Bool
    /// When false the Audiogram chip is hidden (no thresholds entered yet).
    let hasAudiogram: Bool
    /// When false the Dynamics chip is hidden (no enabled dynamic features).
    let hasDynamics: Bool
    /// Used as the swatch hue for the EQ / Audiogram chips.
    let earColor: Color
    /// When false the spectrum / curve / safety chips (Output, Input,
    /// Result-EQ, Safety) are hidden — on an empty surface with no bands and
    /// no audiogram they toggle overlays that have nothing to show, so they
    /// read as dead controls. Defaults true so surfaces that always carry a
    /// curve (Graphic's 12 bands) are unaffected.
    var hasContent: Bool = true

    /// Local state for the collapsed-layout layers popover.
    @State private var layersPopoverShown: Bool = false

    var body: some View {
        // `ViewThatFits` measures both variants against the available
        // horizontal space and picks the first that fits. At default
        // Dynamic Type + a reasonable window width, the full strip wins.
        // At large accessibility text sizes (or unusually narrow windows)
        // chip widths swell and the full strip overflows — the compact
        // variant takes over, presenting the same controls behind a
        // "Layers" popover so nothing becomes inaccessible.
        ViewThatFits(in: .horizontal) {
            fullStrip
            compactStrip
        }
    }

    /// On Tahoe, GlassEffectContainer lets the chips' glass shapes render
    /// as one merged group — cheaper than N independent glass surfaces and
    /// visually continuous when chips sit close together. Sonoma renders
    /// the bare strip (chips fall back to flat fills there anyway).
    @ViewBuilder
    private var fullStrip: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { fullStripContent }
        } else {
            fullStripContent
        }
    }

    private var fullStripContent: some View {
            HStack(spacing: 8) {
                if hasContent {
                    chip(
                        "Output",
                        swatch: Self.outputColor,
                        isOn: $showOutputSpectrum,
                        hint: "Live post-EQ spectrum — what's leaving the chain."
                    )
                    chip(
                        "Input",
                        swatch: Self.inputColor,
                        isOn: $showInputSpectrum,
                        hint: "Pre-EQ spectrum — what's arriving before the EQ runs."
                    )
                    // Primary curve. With an audiogram it's the "Result" (what
                    // you hear = correction + EQ); without one, Result == EQ, so
                    // it's just labelled "EQ". The two breakdown chips below
                    // only appear when an audiogram makes them carry distinct
                    // information.
                    chip(
                        hasAudiogram ? "Result" : "EQ",
                        swatch: earColor,
                        isOn: $showResultCurve,
                        hint: hasAudiogram
                            ? "What you actually hear — the hearing adjustment and your EQ combined."
                            : "Your active equaliser curve and band handles."
                    )
                    if hasAudiogram {
                        chip(
                            "EQ",
                            swatch: earColor,
                            isOn: $showEQCurve,
                            hint: "Your tone EQ on its own, without the hearing adjustment — the difference from Result is what the adjustment adds."
                        )
                        chip(
                            "Adjustment",
                            swatch: earColor,
                            pattern: .dashed,
                            isOn: $showAudiogramTarget,
                            hint: "The audiogram-derived hearing adjustment on its own."
                        )
                    }
                    chip(
                        "Safety",
                        swatch: Self.safetyColor,
                        isOn: $showSafetyOverlay,
                        hint: "Highlights frequency regions where sustained energy exceeds a hearing-safety threshold."
                    )
                }
                if hasDynamics {
                    chip(
                        "Dynamics",
                        swatch: earColor,
                        pattern: .dashed,
                        isOn: $showDynamics,
                        hint: "Live trace of the Clarity features — shows each dynamic bell moving as it engages."
                    )
                }
                Spacer()
            }
    }

    /// Compact fallback: all layer toggles tucked into a popover so the
    /// bar never overflows at large text sizes / narrow windows.
    @ViewBuilder
    private var compactStrip: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { compactStripContent }
        } else {
            compactStripContent
        }
    }

    private var compactStripContent: some View {
        HStack(spacing: 8) {
            layersButton
            Spacer()
        }
    }

    private var layersButton: some View {
        Button {
            layersPopoverShown.toggle()
        } label: {
            // Mirror the chip silhouette so it reads as part of the strip.
            HStack(spacing: 6) {
                Image(systemName: "rectangle.3.group")
                    .font(.callout.weight(.semibold))
                Text("Layers")
                    .font(.callout.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .glassChipSurface(
                tint: nil,
                fallbackFill: Color.secondary.opacity(0.12),
                fallbackStroke: Color.secondary.opacity(0.40)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show / hide individual canvas layers.")
        .accessibilityLabel("Layers")
        .accessibilityHint("Opens a panel where you can toggle each canvas layer on or off.")
        .popover(isPresented: $layersPopoverShown, arrowEdge: .top) {
            popoverContent
                .padding(16)
                .frame(minWidth: 240)
        }
    }

    @ViewBuilder
    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Visible layers")
                .font(.headline)
            popoverRow(
                "Output",
                swatch: Self.outputColor,
                isOn: $showOutputSpectrum
            )
            popoverRow(
                "Input",
                swatch: Self.inputColor,
                isOn: $showInputSpectrum
            )
            popoverRow(
                hasAudiogram ? "Result" : "EQ",
                swatch: earColor,
                isOn: $showResultCurve
            )
            if hasAudiogram {
                popoverRow(
                    "EQ",
                    swatch: earColor,
                    isOn: $showEQCurve
                )
                popoverRow(
                    "Adjustment",
                    swatch: earColor,
                    pattern: .dashed,
                    isOn: $showAudiogramTarget
                )
            }
            popoverRow(
                "Safety",
                swatch: Self.safetyColor,
                isOn: $showSafetyOverlay
            )
            if hasDynamics {
                popoverRow(
                    "Dynamics",
                    swatch: earColor,
                    pattern: .dashed,
                    isOn: $showDynamics
                )
            }
        }
    }

    /// Single layer row inside the compact-layout popover. Uses a native
    /// `Toggle` so the row gets full Dynamic Type scaling, VoiceOver
    /// semantics, and standard keyboard activation — exactly what the
    /// large-text accessibility audience needs from this fallback.
    private func popoverRow(
        _ label: String,
        swatch: Color,
        pattern: SwatchPattern = .solid,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(swatch)
                    Circle()
                        .strokeBorder(
                            Color.white.opacity(0.45),
                            style: StrokeStyle(
                                lineWidth: 1,
                                dash: pattern == .dashed ? [2, 1.5] : []
                            )
                        )
                }
                .frame(width: 14, height: 14)
                Text(label)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    // MARK: - Chip

    /// Stroke pattern applied to the chip's swatch ring — mirrors the
    /// canvas's redundant encoding so the chip looks like the layer it
    /// controls (solid = solid stroke, dashed = audiogram target).
    private enum SwatchPattern { case solid, dashed }

    private func chip(
        _ label: String,
        swatch: Color,
        pattern: SwatchPattern = .solid,
        isOn: Binding<Bool>,
        hint: String
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 6) {
                // State indicator: checkmark when on. Always reserve the
                // glyph slot so the chip doesn't shift on toggle.
                Image(systemName: isOn.wrappedValue ? "checkmark" : "circle")
                    .font(.caption.weight(.semibold))
                    .frame(width: 12)
                    .foregroundStyle(isOn.wrappedValue ? swatch : Color.secondary)
                // Color swatch — dashed ring for layers that draw dashed.
                ZStack {
                    Circle()
                        .fill(swatch.opacity(isOn.wrappedValue ? 1.0 : 0.35))
                    Circle()
                        .strokeBorder(
                            Color.white.opacity(0.45),
                            style: StrokeStyle(
                                lineWidth: 1,
                                dash: pattern == .dashed ? [2, 1.5] : []
                            )
                        )
                }
                .frame(width: 12, height: 12)
                Text(label)
                    .font(.callout)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            // Glass chip body on Tahoe — tinted with the layer swatch when
            // on, plain when off; flat fill + stroke on Sonoma. On/off
            // keeps its non-color signals (checkmark glyph + swatch
            // opacity) for colorblind users on both.
            .glassChipSurface(
                tint: isOn.wrappedValue ? swatch.opacity(0.25) : nil,
                fallbackFill: isOn.wrappedValue ? swatch.opacity(0.12) : Color.clear,
                fallbackStroke: isOn.wrappedValue ? swatch.opacity(0.55) : Color.secondary.opacity(0.35)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hint)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(isOn.wrappedValue ? "on" : "off"))
        .accessibilityHint(Text(hint))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Layer colors

    /// Violet — matches the post-EQ spectrum gradient.
    static let outputColor = Color(red: 0.48, green: 0.22, blue: 0.72)
    /// Desaturated cool gray — matches the pre-EQ silhouette's mid stop.
    /// Picked closer to neutral than the on-canvas hue so the chip swatch
    /// reads cleanly against both the chip's "off" background and the chip
    /// strip's window background.
    static let inputColor = Color(red: 0.55, green: 0.60, blue: 0.68)
    /// Amber — matches the safety overlay.
    static let safetyColor = Color(red: 1.0, green: 0.65, blue: 0.20)
}
