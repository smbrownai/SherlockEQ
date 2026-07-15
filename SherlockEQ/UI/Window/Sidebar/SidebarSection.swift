import Foundation

/// All sections the main-window sidebar can navigate to. Used as the
/// `NavigationSplitView` selection value, so a single change here updates
/// the sidebar list and the detail-view switch in `MainWindowView`.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case profiles
    case audiogram
    case equalizer
    case toneFinder
    case clarity
    case safeListening
    case settings
    case debug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profiles:      return "Profiles"
        case .audiogram:     return "Audiogram"
        case .equalizer:     return "Equalizer"
        case .toneFinder:    return "Tinnitus Tools"
        case .clarity:       return "Adaptive Comfort"
        case .safeListening: return "Safe Listening"
        case .settings:      return "Settings"
        case .debug:         return "Debug"
        }
    }

    var symbol: String {
        switch self {
        case .profiles:      return "person.crop.circle"
        case .audiogram:     return "ear"
        case .equalizer:     return "slider.horizontal.3"
        case .toneFinder:    return "bandage"
        case .clarity:       return "waveform.badge.magnifyingglass"
        case .safeListening: return "shield.lefthalf.filled"
        case .settings:      return "gearshape"
        case .debug:         return "wrench.and.screwdriver"
        }
    }

    /// **Sound** — the core signal-shaping surfaces. `.profiles` is reached
    /// via the persistent active-profile button at the bottom of the sidebar,
    /// not from a list entry, to avoid a redundant top + bottom entry.
    static var soundSections: [SidebarSection] {
        [.equalizer, .audiogram]
    }

    /// **Comfort & Safety** — the level-following comfort tools, tinnitus
    /// tools, and listening-safety monitor, grouped so they read as
    /// "protect and ease listening" rather than "shape the signal."
    static var comfortSafetySections: [SidebarSection] {
        [.clarity, .toneFinder, .safeListening]
    }

    /// App-level sections — settings and diagnostics. Grouped under
    /// their own header so they read as "things about the app" rather
    /// than "things about the audio." `.debug` is opt-in (off by
    /// default) via the Settings → General "Show Debug in sidebar"
    /// toggle, so it's only included when `showDebug` is true.
    static func appSections(showDebug: Bool) -> [SidebarSection] {
        showDebug ? [.settings, .debug] : [.settings]
    }
}
