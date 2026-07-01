import Foundation
import OSLog

/// Models + parsers for the on-demand AutoEQ integration. Two phases:
///
///   Phase 1 — fetch the AutoEQ project's `results/README.md`, parse out
///   every headphone entry, and keep that index on disk so the user can
///   search ~6,000 profiles without touching the network per keystroke.
///
///   Phase 2 — when the user picks a result, fetch the matching
///   `ParametricEQ.txt`, parse it, and cache the structured profile
///   alongside the index.
///
/// All file I/O lives under `Application Support/SherlockEQ/`. All network
/// traffic goes to `raw.githubusercontent.com`. No accounts, no tokens, no
/// analytics — see the privacy section of the integration spec.

// MARK: - Phase 1: index

/// One headphone entry parsed from the AutoEQ `results/README.md`.
struct AutoEQIndexEntry: Codable, Hashable, Identifiable {
    let name: String        // "Sennheiser HD 650"
    let path: String        // "oratory1990/over-ear/Sennheiser HD 650"
    let source: String      // "oratory1990"
    let type: String        // "over-ear" / "in-ear" / "earbud"

    /// The identifier the saved-profiles AppStorage list keys off. The
    /// path is unique within the AutoEQ catalog (source + type + name),
    /// human-readable in logs, and survives renames the same way as the
    /// catalog does — i.e. it doesn't.
    var id: String { path }
}

/// Stored shape of `autoeq_index.json`. Bundles the array of entries
/// with the fetch timestamp so refresh logic can compare against
/// `7 days`.
struct AutoEQIndex: Codable {
    let entries: [AutoEQIndexEntry]
    let fetchedAt: Date
}

// MARK: - Phase 2: profile

/// Wire-format filter type from a ParametricEQ.txt file. Distinct from
/// the app's broader `EQFilterType` (which carries notch / band-pass /
/// low-pass / high-pass cases AutoEQ never emits) so the wire model
/// stays narrow to what we'll actually see from the AutoEQ producers.
enum AutoEQRemoteFilterType: String, Codable {
    case peak      = "PK"
    case lowShelf  = "LSC"
    case highShelf = "HSC"

    /// Map to the in-app filter type used by `EQBand` and the biquad cascade.
    var asEQFilterType: EQFilterType {
        switch self {
        case .peak:      return .parametric
        case .lowShelf:  return .lowShelf
        case .highShelf: return .highShelf
        }
    }
}

/// One filter row parsed from a ParametricEQ.txt file. Stored as a
/// structured value so the cache file is self-describing without
/// having to re-parse the original text every time it's loaded.
struct AutoEQRemoteFilter: Codable, Hashable {
    let index: Int
    let enabled: Bool
    let filterType: AutoEQRemoteFilterType
    let frequency: Double         // Hz
    let gain: Double              // dB
    let q: Double                 // clamped to 0.1...16

    /// Convert to the app's audio-graph band shape. `enabled` is
    /// preserved on the band itself so disabled-but-cached filters
    /// don't accidentally re-enter the chain if we later loosen the
    /// "skip OFF" parser rule.
    var asEQBand: EQBand {
        EQBand(
            frequencyHz: frequency,
            gaindB: gain,
            bandwidth: q,
            filterType: filterType.asEQFilterType,
            enabled: enabled
        )
    }
}

/// A single fetched + parsed AutoEQ profile. This is what gets cached
/// at `Application Support/SherlockEQ/autoeq_profiles/{source}/{type}/{name}.json`
/// and surfaced through the saved-profiles list.
struct AutoEQRemoteProfile: Codable, Hashable {
    let headphoneName: String     // "Sennheiser HD 650"
    let source: String            // "oratory1990"
    let type: String              // "over-ear"
    let preampGain: Double        // negative dB value from the file
    let filters: [AutoEQRemoteFilter]
    let fetchedAt: Date

    /// Catalog identifier — matches the `path` field on `AutoEQIndexEntry`.
    /// Recomputed from source/type/name rather than stored separately so
    /// the on-disk shape stays minimal.
    var path: String { "\(source)/\(type)/\(headphoneName)" }

    /// The set of EQ bands the audio engine will run. Only enabled
    /// filters cross over — the parser already skips OFF rows but the
    /// conversion stays defensive.
    var bands: [EQBand] {
        filters.filter(\.enabled).map(\.asEQBand)
    }
}

// MARK: - Index parser

/// Parses the AutoEQ project's `results/README.md` markdown list into
/// the structured index. Tolerates extra prose, headers, and blank
/// lines around the entries — only lines that match the canonical
/// `- [Name](./path)` pattern contribute.
enum AutoEQIndexParser {

    /// One markdown row looks like `- [Sennheiser HD 650](./oratory1990/over-ear/Sennheiser%20HD%20650)`.
    /// The path is URL-encoded in the markdown source so we percent-decode
    /// before storing; downstream callers re-encode per component when
    /// building fetch URLs (see `AutoEQRemoteService.profileURL(for:)`).
    static let pattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"^\s*-\s*\[([^\]]+)\]\(\.\/([^)]+)\)\s*$"#,
            options: []
        )
    }()

    static func parse(_ text: String) -> [AutoEQIndexEntry] {
        var entries: [AutoEQIndexEntry] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let entry = parseLine(line) else { continue }
            entries.append(entry)
        }
        return entries
    }

    private static func parseLine(_ line: String) -> AutoEQIndexEntry? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = pattern.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges == 3,
              let nameRange = Range(match.range(at: 1), in: line),
              let pathRange = Range(match.range(at: 2), in: line) else {
            return nil
        }
        let name = String(line[nameRange]).trimmingCharacters(in: .whitespaces)
        let encodedPath = String(line[pathRange]).trimmingCharacters(in: .whitespaces)
        // README encodes spaces as %20, etc. Decode for storage.
        let decodedPath = encodedPath.removingPercentEncoding ?? encodedPath
        let components = decodedPath.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return nil }
        let source = components[0]
        let type = components[1]
        return AutoEQIndexEntry(
            name: name,
            path: decodedPath,
            source: source,
            type: type
        )
    }
}

// MARK: - ParametricEQ.txt parser (spec semantics)

/// Parses a ParametricEQ.txt into the spec-defined structured profile.
///
/// Distinct from the legacy `AutoEQParser` (which returns the audio-graph
/// `EQBand` directly for the file-picker import path) so the remote
/// integration can keep the wire-format model in its own type space —
/// useful when caching a fetched profile and surfacing its original
/// fields (e.g. Q before clamp, filter index, etc.) in the saved-list
/// row metadata later. The `AutoEQRemoteProfile.bands` accessor still
/// converts to `EQBand` at the apply boundary.
enum AutoEQRemoteParser {

    private static let log = Logger(subsystem: "com.shawnbrown.SherlockEQ", category: "AutoEQRemoteParser")

    static func parse(_ text: String, entry: AutoEQIndexEntry, fetchedAt: Date = Date()) -> AutoEQRemoteProfile? {
        // We collect what we can; only the *whole* parse fails when there
        // is no usable filter at the end. Per spec: a missing Preamp line
        // defaults to 0 dB + a warning. Individual filter parse errors
        // are logged and skipped, not propagated.

        var preamp: Double = 0
        var sawPreamp = false
        var filters: [AutoEQRemoteFilter] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let lower = line.lowercased()
            if lower.hasPrefix("preamp:") {
                if let value = numericToken(after: "Preamp:", in: line), value.isFinite {
                    preamp = max(-BiquadCoefficients.gainClampDB, min(BiquadCoefficients.gainClampDB, value))
                    sawPreamp = true
                } else {
                    log.warning("Could not parse Preamp value in \(entry.path, privacy: .public)")
                }
                continue
            }

            if lower.hasPrefix("filter") {
                if let filter = parseFilter(line) {
                    filters.append(filter)
                }
                continue
            }
        }

        if !sawPreamp {
            log.warning("Preamp line missing in \(entry.path, privacy: .public); defaulting to 0 dB")
        }

        guard !filters.isEmpty else { return nil }

        return AutoEQRemoteProfile(
            headphoneName: entry.name,
            source: entry.source,
            type: entry.type,
            preampGain: preamp,
            filters: filters,
            fetchedAt: fetchedAt
        )
    }

    /// Parse one `Filter N: ON PK Fc 100 Hz Gain -3.5 dB Q 1.0` row.
    /// Returns nil when the line is malformed, the state token is OFF
    /// (skip per spec), or the filter type is unrecognized (skip + log).
    private static func parseFilter(_ line: String) -> AutoEQRemoteFilter? {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        // Need at least "Filter N: ON TYPE" (4 tokens). Fc/Gain are required;
        // Q is optional (handled below), so a Q-less row like
        // "Filter 1: ON PK Fc 100 Hz Gain -3.5 dB" (10 tokens) is valid and
        // must not be rejected here — the old `>= 11` guard dropped it.
        guard tokens.count >= 4 else {
            log.warning("Filter line has too few tokens: \(line, privacy: .public)")
            return nil
        }

        // "Filter" "1:" — index lives in tokens[1] stripped of the trailing colon.
        let indexToken = tokens[1].trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        let index = Int(indexToken) ?? 0

        let stateToken = tokens[2].uppercased()
        let enabled = stateToken == "ON"
        if stateToken == "OFF" {
            // Per spec: skip disabled filters entirely (they're not
            // added to the parsed profile). Return nil without a
            // warning — disabled rows are legitimate, not a parse error.
            return nil
        } else if !enabled {
            log.warning("Unrecognized state token '\(stateToken, privacy: .public)' in: \(line, privacy: .public)")
            return nil
        }

        let typeToken = tokens[3].uppercased()
        guard let filterType = AutoEQRemoteFilterType(rawValue: typeToken) else {
            log.warning("Unrecognized filter type '\(typeToken, privacy: .public)' in: \(line, privacy: .public)")
            return nil
        }

        guard let fc = numericAfter("Fc", in: tokens),
              let gain = numericAfter("Gain", in: tokens) else {
            log.warning("Missing Fc/Gain in: \(line, privacy: .public)")
            return nil
        }
        // Q optional — default to Butterworth (0.707) when absent rather than
        // dropping the row, which silently produced a partial correction.
        let q = max(0.1, min(16.0, numericAfter("Q", in: tokens) ?? 0.707))

        return AutoEQRemoteFilter(
            index: index,
            enabled: enabled,
            filterType: filterType,
            frequency: fc,
            gain: gain,
            q: q
        )
    }

    /// Look up the token immediately after a labeled field (Fc/Gain/Q).
    /// Tolerates "Fc 100" and "Fc 100.0" — strips any trailing unit
    /// suffix on the value itself ("100Hz" → 100) before parsing.
    private static func numericAfter(_ label: String, in tokens: [String]) -> Double? {
        guard let idx = tokens.firstIndex(where: { $0.caseInsensitiveCompare(label) == .orderedSame }),
              idx + 1 < tokens.count else { return nil }
        return parseUnitlessDouble(tokens[idx + 1])
    }

    /// "Preamp: -6.5 dB" → -6.5
    private static func numericToken(after prefix: String, in line: String) -> Double? {
        guard let range = line.range(of: prefix, options: .caseInsensitive) else { return nil }
        let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let first = rest.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? String(rest)
        return parseUnitlessDouble(first)
    }

    /// Strip optional Hz/dB unit suffix attached without a space (rare
    /// but seen in some exports), then parse as Double.
    private static func parseUnitlessDouble(_ token: String) -> Double? {
        var working = token
        for unit in ["Hz", "hz", "dB", "db"] {
            if working.hasSuffix(unit) {
                working = String(working.dropLast(unit.count))
                break
            }
        }
        return Double(working)
    }
}
