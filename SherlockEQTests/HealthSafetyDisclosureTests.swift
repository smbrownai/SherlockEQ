import Testing
@testable import SherlockEQ

/// Guards the single-source disclosure content: the sheet's required
/// plain-language statements can't silently disappear, the section set stays
/// complete, and every Help link resolves to a real article.
struct HealthSafetyDisclosureTests {

    /// All section text concatenated — the corpus the required-statement
    /// checks scan (case-insensitively).
    private var corpus: String {
        let parts = HealthSafetyDisclosure.sections.flatMap { section in
            [section.title] + section.paragraphs
        }
        return (parts + [HealthSafetyDisclosure.summary,
                         HealthSafetyDisclosure.chipLead,
                         HealthSafetyDisclosure.chipAction]).joined(separator: "\n").lowercased()
    }

    @Test func hasAllRequestedSections() {
        let ids = Set(HealthSafetyDisclosure.sections.map(\.id))
        let expected: Set<String> = [
            "about", "not-medical", "audiogram", "tinnitus",
            "levels", "safe-use", "consult", "privacy",
        ]
        #expect(ids == expected)
    }

    @Test func statesConsumerAudioNotMedical() {
        let c = corpus
        #expect(c.contains("consumer audio"))
        #expect(c.contains("not a medical device"))
        #expect(c.contains("hearing aid"))
    }

    @Test func statesDoesNotDiagnoseTreatCurePrevent() {
        #expect(corpus.contains("does not diagnose, treat, cure, or prevent"))
    }

    @Test func statesAdjustmentsAreStartingPointsNotClinical() {
        let c = corpus
        #expect(c.contains("starting point"))
        #expect(c.contains("not clinical fittings") || c.contains("not a clinical fitting"))
        #expect(c.contains("real-ear verification"))
    }

    @Test func statesLevelsAreEstimates() {
        let c = corpus
        #expect(c.contains("estimate"))
        #expect(c.contains("output device") && c.contains("calibrat"))
    }

    @Test func statesStopTonesOnDiscomfort() {
        let c = corpus
        #expect(c.contains("stop"))
        #expect(c.contains("discomfort") && c.contains("pain") && c.contains("dizziness"))
    }

    @Test func statesWhenToConsultAProfessional() {
        let c = corpus
        #expect(c.contains("sudden"))
        #expect(c.contains("one ear"))
        #expect(c.contains("healthcare professional"))
    }

    @Test func statesLocalProcessingPrivacy() {
        let c = corpus
        #expect(c.contains("processed on your mac"))
        // "Nothing you play is recorded, saved, or sent anywhere."
        #expect((c.contains("nothing") || c.contains("never"))
                && (c.contains("recorded") || c.contains("sent")))
    }

    @Test func everyLearnMoreLinkResolves() {
        // Section links + the footer "Learn more" list must all point at real
        // Help articles (non-empty slug).
        for section in HealthSafetyDisclosure.sections {
            if let topic = section.learnMore {
                #expect(!topic.slug.isEmpty)
            }
        }
        for entry in HealthSafetyDisclosure.learnMoreTopics {
            #expect(!entry.topic.slug.isEmpty)
            #expect(!entry.label.isEmpty)
        }
    }

    @Test func chipCopyIsNonEmpty() {
        #expect(!HealthSafetyDisclosure.chipLead.isEmpty)
        #expect(HealthSafetyDisclosure.chipAction.contains("Health & Safety"))
    }
}
