import Foundation

/// Stable identifiers for every help article. The raw value is the
/// document slug — it matches the markdown filename (`<slug>.md`) and
/// the `slug:` field in that file's front-matter, so routing, menu
/// items, and contextual `?` buttons all refer to one source of truth.
///
/// Adding a topic is a three-step change: a case here, a `<slug>.md`
/// file in `Documentation/`, and (optionally) a menu entry in
/// `HelpMenu.items`. The library validates at launch that every case
/// has a backing document, so a missing file fails loudly in debug.
enum HelpTopic: String, CaseIterable, Hashable, Sendable {
    case home = "index"
    case gettingStarted = "getting-started"
    case featureGuide = "feature-guide"
    case understandingEQ = "understanding-eq"
    case gainVolume = "gain-volume"
    case balance = "balance"
    case graphicEQ = "graphic-eq"
    case parametricEQ = "parametric-eq"
    case perEarEQ = "per-ear-eq"
    case audiogramProfiles = "audiogram-profiles"
    case tinnitusToneMatching = "tinnitus-tone-matching"
    case headphoneCorrection = "headphone-correction-autoeq"
    case listeningComfort = "listening-comfort"
    case vuMeters = "vu-meters"
    case spectrumVisualization = "spectrum-visualization"
    case analogControlUnit = "analog-control-unit"
    case outputDevices = "output-devices"
    case profiles = "profiles"
    case safetyLimits = "safety-limits"
    case privacy = "privacy-local-data"
    case troubleshooting = "troubleshooting"
    case keyboardShortcuts = "keyboard-shortcuts"
    case commandLineTool = "command-line-tool"
    case releaseNotes = "release-notes"
    case references = "references"

    var slug: String { rawValue }

    /// Maps an arbitrary slug (e.g. parsed from an internal `[text](help:slug)`
    /// link in markdown) back to a topic, if one exists.
    init?(slug: String) {
        self.init(rawValue: slug)
    }
}
