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
    case meters
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
        case .meters:        return "Meters"
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
        case .meters:        return "gauge.with.dots.needle.50percent"
        case .settings:      return "gearshape"
        case .debug:         return "wrench.and.screwdriver"
        }
    }

    /// Sections shown under the "Library" header. Debug lives on its own
    /// below so it's visually separated from the primary navigation.
    static var librarySections: [SidebarSection] {
        [.profiles, .audiogram, .equalizer, .toneFinder, .safeListening, .meters, .settings]
    }
}
