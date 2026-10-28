import XCTest

/// Drives the real setup flow on a simulator. Guards the bug where the measurements
/// screen opened with an empty profile after the scan or manual entry.
final class ProfileSetupUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testManualEntryOpensWithHeightAndEstimates() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-onboardingCompleted", "NO"]
        app.launch()

        // Four onboarding pages, then setup.
        for _ in 0..<3 { app.buttons["Continue"].tap() }
        app.buttons["Get started"].tap()

        // About you: defaults (175 cm, 75 kg) are fine.
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 5))
        app.buttons["Continue"].tap()

        XCTAssertTrue(app.buttons["Enter measurements manually"].waitForExistence(timeout: 5))
        app.buttons["Enter measurements manually"].tap()

        XCTAssertTrue(app.navigationBars["Your measurements"].waitForExistence(timeout: 5))
        // Each row is one combined accessibility element: "Height, Entered, 175 cm".
        let height = app.buttons.matching(NSPredicate(format: "label CONTAINS '175 cm'")).firstMatch
        XCTAssertTrue(height.waitForExistence(timeout: 3), "height missing on the review screen")
        let estimates = app.buttons.matching(NSPredicate(format: "label CONTAINS '±'"))
        XCTAssertGreaterThanOrEqual(estimates.count, 5, "height/weight estimates missing on the review screen")
        XCTAssertFalse(app.staticTexts["Without chest and waist we can't recommend sizes yet."].exists)
    }
}
