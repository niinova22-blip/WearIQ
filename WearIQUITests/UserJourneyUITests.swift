import XCTest

/// A shopper's first session, driven like a person would: setup with typed-in
/// measurements, a quick check of a T-shirt from its tag, the result and the avatar, then
/// every tab and every row of the profile's settings. Each screen must open and come
/// back without the app getting stuck or crashing.
final class UserJourneyUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        executionTimeAllowance = 300
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-onboardingCompleted", "NO",
                                "-WQUITest", "YES", "-soundsEnabled", "NO"]
        app.launch()
    }

    private func tap(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 8) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(what) missing")
        element.tap()
    }

    /// A button whose label contains `text` (icons add their own words to a label).
    private func button(containing text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Scrolls the screen until `element` is on it: a SwiftUI list only builds the rows
    /// in view, so a row further down doesn't exist until it's scrolled to.
    @discardableResult
    private func scrolledTo(_ element: XCUIElement, _ what: String, down: Bool = true) -> XCUIElement {
        for _ in 0..<12 {
            if element.waitForExistence(timeout: 1.5), element.isHittable { return element }
            if down { app.swipeUp() } else { app.swipeDown() }
        }
        XCTFail("\(what) not found on the screen")
        return element
    }

    /// Back from a pushed screen (the navigation bar's first button).
    private func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    func testFirstSessionAndEverySetting() {
        // Setup: onboarding, about you, measurements typed in, saved.
        for _ in 0..<3 { tap(app.buttons["Continue"], "onboarding Continue") }
        tap(app.buttons["Get started"], "Get started")
        tap(app.buttons["Male"], "gender")
        tap(app.buttons["Continue"], "about you Continue")
        tap(app.buttons["Enter measurements manually"], "manual entry")
        XCTAssertTrue(app.navigationBars["Your measurements"].waitForExistence(timeout: 8))
        tap(app.buttons["Save measurements"], "Save measurements")

        // Home.
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 15), "tabs missing after setup")
        XCTAssertTrue(app.staticTexts["Will it fit you?"].waitForExistence(timeout: 5))

        // Scan → Quick check: a T-shirt, size M on the tag.
        tap(app.tabBars.buttons["Scan"], "Scan tab")
        tap(button(containing: "Quick check"), "Quick check")
        tap(button(containing: "T-shirt"), "T-shirt chip")
        tap(app.buttons["M"], "size M chip")
        tap(app.buttons["quickCheckSubmit"], "Check the fit")
        XCTAssertTrue(app.navigationBars["Fit analysis"].waitForExistence(timeout: 20), "no result after the quick check")
        let tagLine = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'tag'")).firstMatch
        XCTAssertTrue(tagLine.waitForExistence(timeout: 5), "the result doesn't compare with the size on the tag")

        // The result on the avatar, then back.
        let avatar = button(containing: "See it on my avatar")
        app.swipeUp()
        tap(avatar, "See it on my avatar")
        tap(app.buttons["Done"], "avatar Done", timeout: 30)
        XCTAssertTrue(app.navigationBars["Fit analysis"].waitForExistence(timeout: 8))

        // The check is in the history on Home.
        tap(app.tabBars.buttons["Home"], "Home tab")
        XCTAssertTrue(app.staticTexts["Recent analyses"].waitForExistence(timeout: 8), "the check isn't in the history")

        // Wardrobe and Style open (Style shows the paywall on the free plan).
        tap(app.tabBars.buttons["Wardrobe"], "Wardrobe tab")
        tap(app.tabBars.buttons["Style"], "Style tab")
        XCTAssertTrue(app.navigationBars["Style"].waitForExistence(timeout: 8))

        // Profile: every row opens and comes back; every toggle and picker answers.
        tap(app.tabBars.buttons["Profile"], "Profile tab")
        scrolledTo(app.buttons["Edit measurements"], "Edit measurements (the profile has no measurements)")
        for row in ["Size passport", "Shopping memory", "Measurement changes", "My 3D avatar"] {
            scrolledTo(app.buttons[row], row).tap()
            if row == "My 3D avatar" {
                XCTAssertTrue(app.staticTexts["Chest"].waitForExistence(timeout: 30), "the 3D body's sliders are missing")
            }
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 8))
            back()
            XCTAssertTrue(app.tabBars.buttons["Profile"].waitForExistence(timeout: 8), "\(row) didn't come back")
        }

        scrolledTo(app.switches["Interface sounds"], "Interface sounds").tap()
        scrolledTo(app.buttons["Size system"], "Size system picker").tap()
        tap(app.buttons["Türkiye"], "Türkiye size system")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'jeans 31/32'")).firstMatch
            .waitForExistence(timeout: 5), "the size system footer didn't follow the choice")

        scrolledTo(app.buttons["Acknowledgements"], "Acknowledgements").tap()
        XCTAssertTrue(app.navigationBars["Acknowledgements"].waitForExistence(timeout: 5))
        back()

        // Delete everything: back to the introduction.
        scrolledTo(app.buttons["Delete all my data"], "Delete all my data").tap()
        tap(app.buttons["Delete"], "confirm Delete")
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 10), "deleting didn't return to the introduction")
    }
}
