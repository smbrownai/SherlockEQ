import Foundation

/// Single source of truth for SherlockEQ's health & safety disclosure.
///
/// Every screen that needs disclosure — the persistent sidebar item, the
/// compact "not medical care" chips, and the consolidated sheet — reads its
/// copy from here, so the wording can't drift into slightly-different copies
/// across views. The sheet renders `sections`; contextual chips use `chip*`.
///
/// **Wording note (for legal / audiology review):** the statements here
/// preserve the substance of the disclosures they replace and use
/// conservative, standard phrasing. They make no regulatory-approval or
/// treatment claims. The medical-device / "does not diagnose, treat, cure, or
/// prevent" language and the red-flag-symptom list are legally and medically
/// consequential and are flagged for professional review — they should not be
/// reworded casually.
enum HealthSafetyDisclosure {

    // MARK: - Header

    static let title = "Health & Safety"

    /// One calm sentence that frames the whole sheet.
    static let summary = "SherlockEQ is a consumer audio tool for everyday listening — not medical care. Here's what that means, how to use it safely, and when to seek professional help."

    // MARK: - Compact chip (repeated-card replacement)

    /// Lead-in shown on the compact disclosure chip. The action label
    /// (`chipAction`) opens the sheet.
    static let chipLead = "Consumer audio tools — not medical care."
    static let chipAction = "Health & Safety…"

    // MARK: - Sections

    struct Section: Identifiable {
        let id: String
        let title: String
        let symbol: String
        /// Short scannable paragraphs — plain language, no legal wall.
        let paragraphs: [String]
        /// Optional Help article for the deep-dive.
        let learnMore: HelpTopic?
    }

    static let sections: [Section] = [
        Section(
            id: "about",
            title: "About SherlockEQ",
            symbol: "app.badge",
            paragraphs: [
                "SherlockEQ is a consumer audio-processing application. It shapes the sound your Mac plays — equalization, per-ear balance, a tinnitus notch, and comfort tools — so everyday listening to music, video, and speech can feel clearer or easier."
            ],
            learnMore: .gettingStarted
        ),
        Section(
            id: "not-medical",
            title: "Not a medical device or hearing aid",
            symbol: "cross.case",
            paragraphs: [
                "SherlockEQ is not a medical device and not a hearing aid.",
                "It does not diagnose, treat, cure, or prevent hearing loss, tinnitus, or any other health condition, and it implies no regulatory approval."
            ],
            learnMore: .safetyLimits
        ),
        Section(
            id: "audiogram",
            title: "Audiograms and hearing adjustments",
            symbol: "ear",
            paragraphs: [
                "Audiogram-derived adjustments are conservative listening starting points you fine-tune by ear — not clinical fittings.",
                "A static equalizer can't provide the calibrated, level-dependent processing, output limiting, and real-ear verification a professionally fitted hearing aid uses. Treat any adjustment as a comfort preference, not a correction of a measured loss."
            ],
            learnMore: .audiogramProfiles
        ),
        Section(
            id: "tinnitus",
            title: "Tinnitus tools and test tones",
            symbol: "waveform.path",
            paragraphs: [
                "The tinnitus tools let you explore a notch around a pitch you match by ear and track how bothersome the ringing feels. They don't treat tinnitus, and evidence for notched-sound approaches is mixed.",
                "Test tones should begin quietly. Stop immediately if a tone causes discomfort, pain, dizziness, or worsening symptoms."
            ],
            learnMore: .tinnitusToneMatching
        ),
        Section(
            id: "levels",
            title: "Listening-level estimates and calibration",
            symbol: "gauge.with.dots.needle.bottom.50percent",
            paragraphs: [
                "Listening-level and exposure (dose) values are estimates, not measurements. Their accuracy depends on your output device, your volume, and whether you've set the playback calibration.",
                "Without calibration the estimate shows the right shape but not a true level; when audio isn't playing there's no level to show at all."
            ],
            learnMore: .safetyLimits
        ),
        Section(
            id: "safe-use",
            title: "Safe use and when to stop",
            symbol: "hand.raised",
            paragraphs: [
                "Keep levels comfortable, take regular breaks, and start any test tone or large boost quietly.",
                "Stop right away if listening becomes uncomfortable or causes pain, ringing, fullness, or dizziness."
            ],
            learnMore: .safetyLimits
        ),
        Section(
            id: "consult",
            title: "When to consult a hearing professional",
            symbol: "stethoscope",
            paragraphs: [
                "A sudden change in hearing, a change in one ear, ear pain, drainage, dizziness, pulsatile (heartbeat-like) tinnitus, or other concerning symptoms warrant evaluation by an appropriate healthcare professional.",
                "SherlockEQ can't assess these, and no amount of audio tuning is a substitute for that evaluation."
            ],
            learnMore: nil
        ),
        Section(
            id: "privacy",
            title: "Privacy and local processing",
            symbol: "lock.shield",
            paragraphs: [
                "Audio is processed on your Mac in real time. Nothing you play is recorded, saved, or sent anywhere, and your profiles stay in local files you control."
            ],
            learnMore: .privacy
        ),
    ]

    /// The "Learn more" footer — the Help articles most relevant to health &
    /// safety, gathered in one place.
    static let learnMoreTopics: [(topic: HelpTopic, label: String)] = [
        (.safetyLimits, "Safe listening & limits"),
        (.audiogramProfiles, "Audiograms & hearing adjustments"),
        (.tinnitusToneMatching, "Tinnitus tools"),
        (.privacy, "Privacy & local data"),
    ]
}
