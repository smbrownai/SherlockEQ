import SwiftUI

/// What a control's value belongs to. A consistent vocabulary so every
/// adjustable value can say, at a glance, whether changing it affects the
/// whole app, just this profile, the current device, one ear, or today's
/// session — the cross-app "clarify control scope" convention.
enum ControlScope {
    case app
    case profile
    case device
    case leftEar
    case rightEar
    case session

    var label: String {
        switch self {
        case .app:      return "App"
        case .profile:  return "Profile"
        case .device:   return "Device"
        case .leftEar:  return "Left ear"
        case .rightEar: return "Right ear"
        case .session:  return "Today"
        }
    }

    var symbol: String {
        switch self {
        case .app:      return "macwindow"
        case .profile:  return "person.crop.circle"
        case .device:   return "hifispeaker"
        case .leftEar, .rightEar: return "ear"
        case .session:  return "clock"
        }
    }

    var help: String {
        switch self {
        case .app:      return "App-wide — the same value everywhere in SherlockEQ."
        case .profile:  return "Saved with the active profile — switching profiles can change it."
        case .device:   return "Tied to the current output device."
        case .leftEar:  return "Affects the left ear only."
        case .rightEar: return "Affects the right ear only."
        case .session:  return "Accumulates over today's listening; resets at midnight."
        }
    }
}

/// Quiet capsule that marks a control's scope. Small and secondary — a
/// reference cue, not a shout. Pair it with a control's label.
struct ScopeBadge: View {
    let scope: ControlScope

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: scope.symbol)
                .font(.system(size: 8, weight: .semibold))
            Text(scope.label)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .help(scope.help)
        .accessibilityLabel("Scope: \(scope.label). \(scope.help)")
    }
}
