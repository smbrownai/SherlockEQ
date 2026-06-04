import Foundation

/// All sections the main-window sidebar can navigate to. Used as the
/// `NavigationSplitView` selection value, so a single change here updates
/// the sidebar list and the detail-view switch in `MainWindowView`.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case profiles
    case audiogram
    case equalizer
    case toneFinder
    case safeListening
    case settings
    case debug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profiles:      return "Profiles"
        case .audiogram:     return "Audiogram"
        case .equalizer:     return "Equalizer"
        case .toneFinder:    return "Tone Finder"
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
        case .toneFinder:    return "tuningfork"
        case .safeListening: return "shield.lefthalf.filled"
        case .settings:      return "gearshape"
        case .debug:         return "wrench.and.screwdriver"
        }
    }

    /// Audio-processing sections — what shapes the signal on its way
    /// to the user's ears. `.profiles` is reachable via the persistent
    /// "Manage Profiles" button at the bottom of the sidebar, not from
    /// this list, to avoid the redundant top + bottom entry.
    static var audioProcessorSections: [SidebarSection] {
        [.audiogram, .equalizer, .toneFinder, .safeListening]
    }

    /// App-level sections — settings and diagnostics. Grouped under
    /// their own header so they read as "things about the app" rather
    /// than "things about the audio."
    static var appSections: [SidebarSection] {
        [.settings, .debug]
    }
}
