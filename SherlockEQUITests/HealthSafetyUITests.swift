import XCTest

/// UI tests for the Health & Safety disclosure: persistent access from every
/// main destination, opening/dismissing the sheet (button, Done, keyboard),
/// the required section content, Help-link navigation, and the sidebar
/// footer's accessibility + layout.
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

    private var healthSafetyButton: XCUIElement {
        app.buttons["Health and Safety"]
    }

    private var sheetTitle: XCUIElement {
        // The sheet's title text (ampersand distinguishes it from the footer
        // button label "Health and Safety").
        app.staticTexts["Health & Safety"]
    }

    private func openSheet(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(healthSafetyButton.waitForExistence(timeout: 10),
                      "Health & Safety footer item missing", file: file, line: line)
        healthSafetyButton.click()
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5),
                      "Disclosure sheet did not open", file: file, line: line)
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

    /// The footer item exists, carries its VoiceOver label (understandable
    /// without the icon), and is operable — clicking it opens the sheet, which
    /// also proves it isn't obscured.
    func testFooterItemIsPresentAndAccessible() {
        XCTAssertTrue(healthSafetyButton.waitForExistence(timeout: 10))
        XCTAssertEqual(healthSafetyButton.label, "Health and Safety")
        healthSafetyButton.click()
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5),
                      "Footer item should open the sheet (proves it's operable / not obscured)")
    }

    /// Opening from the footer presents the sheet; Done dismisses it.
    func testOpenAndDismissWithDone() {
        openSheet()
        app.buttons["Done"].click()
        XCTAssertFalse(sheetTitle.waitForExistence(timeout: 3),
                       "Sheet should dismiss on Done")
    }

    /// The sheet is keyboard-dismissable (Done is the cancel action → Escape).
    func testDismissWithKeyboard() {
        openSheet()
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertFalse(sheetTitle.waitForExistence(timeout: 3),
                       "Sheet should dismiss on Escape")
    }

    /// Health & Safety is reachable from every main navigation destination.
    func testAccessibleFromEveryDestination() {
        for destination in destinations {
            navigate(to: destination)
            openSheet()
            app.buttons["Done"].click()
            XCTAssertFalse(sheetTitle.waitForExistence(timeout: 3),
                           "Sheet should dismiss before the next destination (\(destination))")
        }
    }

    /// The sheet contains the required, non-negotiable disclosure sections.
    func testSheetShowsRequiredSections() {
        openSheet()
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

    /// A Help link is present and operable (it dismisses the sheet and opens
    /// the Help window). Per-section "Learn more" links were removed — all
    /// Help links now live in the footer "Learn more in Help" list, whose
    /// controls carry "Open Help: <topic>" VoiceOver labels. Matching the old
    /// "learn more" text would hit the footer's *header* (a static text whose
    /// click is a no-op). Query across element types, not `app.buttons`:
    /// `.buttonStyle(.link)` controls don't surface as buttons (verified —
    /// a buttons-only query found nothing at runtime).
    func testLearnMoreLinkOperates() {
        openSheet()
        let predicate = NSPredicate(format: "label BEGINSWITH[c] 'open help'")
        let helpLink = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(helpLink.waitForExistence(timeout: 3), "No footer Help link")
        helpLink.click()
        XCTAssertFalse(sheetTitle.waitForExistence(timeout: 3),
                       "Sheet should dismiss when opening a Help article")
    }
}
