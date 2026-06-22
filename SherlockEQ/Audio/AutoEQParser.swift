import Foundation

/// Parses the text format produced by the AutoEQ project (and the GitHub
/// AutoEq repo, oratory1990 reviews, Crinacle, EqualizerAPO export, etc.).
/// Reference format:
///
///     Preamp: -6.0 dB
///     Filter 1: ON PK Fc 100 Hz Gain -3.5 dB Q 1.000
///     Filter 2: ON LSC Fc 105 Hz Gain 1.5 dB Q 0.71
///     Filter 3: ON HSC Fc 10000 Hz Gain -2.0 dB Q 0.71
///
/// Tolerates blank lines, comments starting with `#`, and varying
/// whitespace. Returns nil if no usable bands could be parsed.
struct ParsedAutoEQ {
    let preampDB: Double
    let bands: [EQBand]
}

enum AutoEQParser {
    static func parse(_ text: String) -> ParsedAutoEQ? {
        var preamp: Double = 0
        var bands: [EQBand] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let lower = line.lowercased()
            if lower.hasPrefix("preamp:") {
                if let v = numericToken(in: line, after: "Preamp:") {
                    preamp = v
                }
                continue
            }
            if lower.hasPrefix("filter") {
                if let band = parseFilter(line) {
                    bands.append(band)
                }
                continue
            }
        }

        guard !bands.isEmpty else { return nil }
        return ParsedAutoEQ(preampDB: preamp, bands: bands)
    }

    private static func parseFilter(_ line: String) -> EQBand? {
        // Tokenise by whitespace, drop the leading "Filter N:" header.
        // Look up Fc / Gain / Q labels positionally so we tolerate the
        // varying decimal precision producers use ("Fc 100 Hz" vs "100.0 Hz").
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        // Need at least "Filter N: ON TYPE" (4 tokens). Fc/Gain are required;
        // Q is optional (handled below), so a Q-less row — e.g.
        // "Filter 1: ON PK Fc 100 Hz Gain -3.5 dB" (10 tokens) — must not be
        // rejected here. The old `>= 11` guard silently dropped such rows.
        guard tokens.count >= 4 else { return nil }

        let stateToken = tokens[2]                  // ON / OFF
        let typeToken  = tokens[3]                  // PK / LSC / HSC / NO / …
        let enabled = stateToken.uppercased() == "ON"

        let filterType: EQFilterType
        switch typeToken.uppercased() {
        case "PK", "PEQ":                  filterType = .parametric
        case "LSC", "LS", "LOWSHELF":      filterType = .lowShelf
        case "HSC", "HS", "HIGHSHELF":     filterType = .highShelf
        case "NO", "OFF", "NONE":          return nil
        default:                           return nil
        }

        guard let fc   = doubleAfter("Fc",   in: tokens),
              let gain = doubleAfter("Gain", in: tokens) else { return nil }
        // Q is optional — EqualizerAPO / oratory1990 exports omit it for
        // default-Q rows. Fall back to 0.707 (Butterworth) instead of dropping
        // the band, which silently yielded a partial correction.
        let q = doubleAfter("Q", in: tokens) ?? 0.707

        return EQBand(
            frequencyHz: fc,
            gaindB: gain,
            bandwidth: q,
            filterType: filterType,
            enabled: enabled
        )
    }

    private static func doubleAfter(_ label: String, in tokens: [String]) -> Double? {
        guard let idx = tokens.firstIndex(where: { $0.caseInsensitiveCompare(label) == .orderedSame }),
              idx + 1 < tokens.count else { return nil }
        return Double(tokens[idx + 1])
    }

    /// `Preamp: -6.0 dB` → -6.0
    private static func numericToken(in line: String, after prefix: String) -> Double? {
        guard let range = line.range(of: prefix, options: .caseInsensitive) else { return nil }
        let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let first = rest.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? rest
        return Double(first)
    }
}
