import Foundation

/// The central data object. One profile per (output device, context, activity)
/// per the spec — users can create as many as they like and switch between them.
struct HearingProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var symbol: String                          // SF Symbol name shown in the sidebar/picker
    var linkedDeviceUID: String?                // optional auto-switch target

    var leftEar: EarProfile
    var rightEar: EarProfile
    var notch: TinnitusNotch
    var globalTrimDB: Double                    // -12 to +12 — guards against post-boost clipping
    var balance: Double                         // -1 (full L) … 0 (centered) … +1 (full R)
    var autoEQCurveURL: URL?                    // optional headphone correction file
    var safeListeningCeilingDB: Double          // user-set, default 85.0
    var compensationFactor: Double              // 0.25–1.0 — audiogram→EQ strength

    var createdAt: Date
    var modifiedAt: Date

    // Custom decoder so older profile JSON (pre-balance) still loads — missing
    // `balance` decodes as 0 (centered). Encoding stays synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id                     = try c.decode(UUID.self, forKey: .id)
        self.name                   = try c.decode(String.self, forKey: .name)
        self.symbol                 = try c.decode(String.self, forKey: .symbol)
        self.linkedDeviceUID        = try c.decodeIfPresent(String.self, forKey: .linkedDeviceUID)
        self.leftEar                = try c.decode(EarProfile.self, forKey: .leftEar)
        self.rightEar               = try c.decode(EarProfile.self, forKey: .rightEar)
        self.notch                  = try c.decode(TinnitusNotch.self, forKey: .notch)
        self.globalTrimDB           = try c.decode(Double.self, forKey: .globalTrimDB)
        self.balance                = try c.decodeIfPresent(Double.self, forKey: .balance) ?? 0
        self.autoEQCurveURL         = try c.decodeIfPresent(URL.self, forKey: .autoEQCurveURL)
        self.safeListeningCeilingDB = try c.decode(Double.self, forKey: .safeListeningCeilingDB)
        self.compensationFactor     = try c.decode(Double.self, forKey: .compensationFactor)
        self.createdAt              = try c.decode(Date.self, forKey: .createdAt)
        self.modifiedAt             = try c.decode(Date.self, forKey: .modifiedAt)
    }

    init(
        id: UUID, name: String, symbol: String, linkedDeviceUID: String?,
        leftEar: EarProfile, rightEar: EarProfile, notch: TinnitusNotch,
        globalTrimDB: Double, balance: Double = 0, autoEQCurveURL: URL?,
        safeListeningCeilingDB: Double, compensationFactor: Double,
        createdAt: Date, modifiedAt: Date
    ) {
        self.id = id; self.name = name; self.symbol = symbol
        self.linkedDeviceUID = linkedDeviceUID
        self.leftEar = leftEar; self.rightEar = rightEar; self.notch = notch
        self.globalTrimDB = globalTrimDB; self.balance = balance
        self.autoEQCurveURL = autoEQCurveURL
        self.safeListeningCeilingDB = safeListeningCeilingDB
        self.compensationFactor = compensationFactor
        self.createdAt = createdAt; self.modifiedAt = modifiedAt
    }
}

extension HearingProfile {
    /// A new, untouched profile. Flat audiogram on both ears, no tinnitus notch,
    /// safe-listening ceiling at the NIOSH-aligned default of 85 dB.
    static func makeDefault(name: String = "Default", symbol: String = "person.fill") -> HearingProfile {
        let now = Date()
        return HearingProfile(
            id: UUID(),
            name: name,
            symbol: symbol,
            linkedDeviceUID: nil,
            leftEar: .flat,
            rightEar: .flat,
            notch: .disabled,
            globalTrimDB: 0,
            autoEQCurveURL: nil,
            safeListeningCeilingDB: 85.0,
            compensationFactor: 0.5,
            createdAt: now,
            modifiedAt: now
        )
    }

    /// Voice Clarity preset from spec §5.8 — boosts the speech-intelligibility
    /// band cluster (1–6 kHz) for podcast monitoring. Same curve both ears.
    static func makeVoiceClarityPreset() -> HearingProfile {
        let now = Date()
        let curve: [EQBand] = [
            EQBand(frequencyHz: 500,  gaindB: 1, bandwidth: 1.0, filterType: .parametric, enabled: true),
            EQBand(frequencyHz: 1000, gaindB: 2, bandwidth: 1.0, filterType: .parametric, enabled: true),
            EQBand(frequencyHz: 2000, gaindB: 3, bandwidth: 1.0, filterType: .parametric, enabled: true),
            EQBand(frequencyHz: 3000, gaindB: 4, bandwidth: 1.0, filterType: .parametric, enabled: true),
            EQBand(frequencyHz: 4000, gaindB: 3, bandwidth: 1.0, filterType: .parametric, enabled: true),
            EQBand(frequencyHz: 6000, gaindB: 1, bandwidth: 1.0, filterType: .parametric, enabled: true),
        ]
        return HearingProfile(
            id: UUID(),
            name: "Voice Clarity",
            symbol: "waveform.badge.mic",
            linkedDeviceUID: nil,
            leftEar: EarProfile(thresholds: AudiogramPoint.flat, bands: curve),
            rightEar: EarProfile(thresholds: AudiogramPoint.flat, bands: curve),
            notch: .disabled,
            globalTrimDB: 0,
            autoEQCurveURL: nil,
            safeListeningCeilingDB: 85.0,
            compensationFactor: 0.5,
            createdAt: now,
            modifiedAt: now
        )
    }
}
