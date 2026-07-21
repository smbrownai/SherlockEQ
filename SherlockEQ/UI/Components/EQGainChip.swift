import AppKit
import SwiftUI

/// Tap-to-edit dB readout used on the Advanced and Expert EQ surfaces.
/// Displays the current gain (e.g. "+3.5"). Tapping focuses an inline
/// text field; Return commits, Esc cancels, focus-out commits.
/// Accepts plain numbers ("3", "-3.5", "+3"), tolerates a trailing "dB",
/// rounds to 0.1 dB, and clamps to the supplied range.
struct EQGainChip: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var tint: Color = .blue
    /// VoiceOver label — the chip exposes its current dB value via
    /// `.accessibilityValue` automatically.
    var accessibilityLabel: String = "Gain"
    /// Readout font — Graphic EQ passes a larger size so the values read
    /// clearly at arm's length; Expert keeps the compact default.
    var valueFont: Font = .caption.monospaced().weight(.medium)
    /// Chip height — grows with `valueFont` on the Graphic surface.
    var height: CGFloat = 18

    @State private var isEditing = false
    @State private var draftText = ""
    @State private var isHovering = false
    @State private var eventMonitor: Any?
    @FocusState private var focused: Bool

    var body: some View {
        if isEditing {
            TextField("", text: $draftText)
                .focused($focused)
                .textFieldStyle(.plain)
                .font(valueFont)
                .multilineTextAlignment(.center)
                .frame(height: height)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(tint, lineWidth: 1)
                )
                .onSubmit { commit() }
                .onExitCommand { cancel() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
                .onHover { isHovering = $0 }
                .onAppear {
                    draftText = String(format: "%.1f", value)
                    focused = true
                    isHovering = true   // tap-to-edit means cursor is over us
                    installOutsideClickMonitor()
                }
                .onDisappear { removeOutsideClickMonitor() }
        } else {
            // Tinted at rest, not just while editing — on surfaces with one
            // chip per ear (Graphic EQ, unlinked), this ties each readout to
            // its ear's color at a glance, matching the slider handle below
            // it and the Left/Right legend above, without relying on the
            // (truncatable) "left"/"right" text alone.
            Text(formattedValue)
                .font(valueFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: height)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(tint.opacity(0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(tint.opacity(0.55), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture { beginEditing() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue("\(formattedValue) decibels")
                .accessibilityHint("Double-tap to type a value")
                .accessibilityAddTraits(.isButton)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: value = clamp(value + 0.5)
                    case .decrement: value = clamp(value - 0.5)
                    @unknown default: break
                    }
                }
                .help("Tap to type a gain value")
        }
    }

    private var formattedValue: String {
        if abs(value) < 0.05 { return "0" }
        return String(format: "%+.1f", value)
    }

    private func beginEditing() {
        draftText = String(format: "%.1f", value)
        isEditing = true
    }

    private func commit() {
        let cleaned = draftText
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "dB", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        if let parsed = Double(cleaned) {
            value = clamp((parsed * 10).rounded() / 10)
        }
        isEditing = false
    }

    private func cancel() {
        isEditing = false
    }

    private func clamp(_ v: Double) -> Double {
        min(max(v, range.lowerBound), range.upperBound)
    }

    // SwiftUI Sliders aren't responders on macOS, so clicking one while
    // the chip's TextField is focused never resigns first-responder and
    // .onChange(of: focused) never fires. Detect outside clicks via a
    // local mouse-down monitor while editing; .onHover tells us whether
    // the cursor is over our chip, so any mouse-down outside that area
    // commits and lets the click fall through to its real target.
    private func installOutsideClickMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                if isEditing && !isHovering { commit() }
            }
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
    }
}
