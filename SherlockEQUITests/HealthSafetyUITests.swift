import XCTest

/// UI tests for the Health & Safety page: reachable from every main
/// destination, showing the required disclosure sections, and offering Help
/// links that leave the page in place.
///
/// It used to be a modal sheet reached from an untagged sidebar button, and
/// these tests were shaped around that — opening it, dismissing with Done,
/// dismissing with Escape. It's an ordinary detail page in Comfort & Safety
/// now, so the dismissal tests are gone rather than rewritten: there is
/// nothing to dismiss, and selecting another sidebar item is how you leave.
///
/// The app launches with `-uitest`, which opens the main window and skips the
/// audio pipeline and onboarding (see `AppDelegate.isUITesting`), so the tests
/// drive the real UI deterministically without the CATap prompt or a wizard.
final class HealthSafetyUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Main sidebar destinations Health & Safety must be reachable from.
    private let destinations = [
        "Equalizer", "Audiogram", "Tinnitus Tools",
        "Adaptive Comfort", "Safe Listening", "Settings",
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitest"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// The sidebar row. Scoped to the outline because the page's own header
    /// carries the same words — in the sheet era a bare "Health & Safety"
    /// was unambiguous, since the row read "Health & Safety Info" and only
    /// the sheet said "Health & Safety".
    private var sidebarRow: XCUIElement {
        app.outlines.firstMatch.staticTexts["Health & Safety"]
    }

    /// Proof the page is showing: a heading that exists nowhere else. Using a
    /// section rather than the title sidesteps the row/header collision
    /// entirely.
    private var pageMarker: XCUIElement {
        app.staticTexts["Not a medical device or hearing aid"]
    }

    private func openHealthSafety(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 10),
                      "Health & Safety sidebar row missing", file: file, line: line)
        sidebarRow.click()
        // The List-backed sidebar can spend a synthesized first click on
        // window activation under XCUITest. One deliberate retry keeps this
        // deterministic without weakening the assertion.
        if !pageMarker.waitForExistence(timeout: 3) {
            sidebarRow.click()
        }
        XCTAssertTrue(pageMarker.waitForExistence(timeout: 5),
                      "Health & Safety page did not appear", file: file, line: line)
    }

    private func navigate(to destination: String) {
        // Scope to the sidebar outline so a matching word elsewhere (e.g. a
        // screen's own "Settings" header) doesn't make the query ambiguous.
        let outline = app.outlines.firstMatch
        let item = outline.staticTexts[destination]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Sidebar item \(destination) missing")
        item.click()
    }

    // MARK: - Tests

    /// The row exists in the sidebar and is operable — selecting it shows the
    /// page, which also proves it isn't obscured.
    func testSidebarRowIsPresentAndOperable() {
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 10))
        openHealthSafety()
    }

    /// It belongs to Comfort & Safety now, not App. Asserted by position: the
    /// row must sit below Safe Listening, the group it joined, and above
    /// Settings, the group it left.
    func testRowSitsInComfortAndSafety() {
        let outline = app.outlines.firstMatch
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 10))
        let safeListening = outline.staticTexts["Safe Listening"]
        let settings = outline.staticTexts["Settings"]
        XCTAssertTrue(safeListening.exists && settings.exists)
        XCTAssertGreaterThan(sidebarRow.frame.minY, safeListening.frame.minY,
                             "Health & Safety should follow Safe Listening")
        XCTAssertLessThan(sidebarRow.frame.minY, settings.frame.minY,
                          "Health & Safety should sit above the App group")
    }

    /// Reachable from every main navigation destination. No dismissal step —
    /// navigating away is simply selecting the next destination.
    func testReachableFromEveryDestination() {
        for destination in destinations {
            navigate(to: destination)
            openHealthSafety()
        }
    }

    /// The page carries the required, non-negotiable disclosure sections.
    func testPageShowsRequiredSections() {
        openHealthSafety()
        let required = [
            "Not a medical device or hearing aid",
            "Audiograms and hearing adjustments",
            "Tinnitus tools and test tones",
            "Listening-level estimates and calibration",
            "What SherlockEQ can't assess",
            "Privacy and local processing",
        ]
        for heading in required {
            XCTAssertTrue(app.staticTexts[heading].waitForExistence(timeout: 3),
                          "Missing disclosure section: \(heading)")
        }
    }

    /// A Help link is present and operable, and the page **stays**.
    ///
    /// This assertion is inverted from the sheet era, and the inversion is the
    /// point: a modal had to dismiss itself before opening Help so the user
    /// wasn't left with a window behind a sheet. A page doesn't, so Help opens
    /// alongside and the reader keeps their place.
    ///
    /// Query across element types, not `app.buttons`: `.buttonStyle(.link)`
    /// controls don't surface as buttons.
    func testLearnMoreLinkLeavesThePageInPlace() {
        openHealthSafety()
        let predicate = NSPredicate(format: "label BEGINSWITH[c] 'open help'")
        let helpLink = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(helpLink.waitForExistence(timeout: 3), "No footer Help link")
        helpLink.click()
        XCTAssertTrue(pageMarker.waitForExistence(timeout: 3),
                      "The page should remain visible behind the Help window")
    }
}
