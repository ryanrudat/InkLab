import XCTest

/// Verifies double-tapping a sticky lets you edit its text. Adds a sticky, double-taps it, types,
/// taps Done, and confirms the new text shows. Captures a screenshot.
final class StickyEditShot: XCTestCase {
    func testEditStickyText() {
        let app = XCUIApplication()
        app.launchEnvironment["INKLAB_TEST_STORE"] = "1"   // a throwaway library, never the real notebooks
        app.launch()

        let firstCover = app.buttons.matching(identifier: "notebookCover").firstMatch
        XCTAssertTrue(firstCover.waitForExistence(timeout: 10))
        firstCover.tap()   // open first notebook
        Thread.sleep(forTimeInterval: 1.0)

        let addSticky = app.buttons["addSticky"]
        XCTAssertTrue(addSticky.waitForExistence(timeout: 5))
        addSticky.tap()
        Thread.sleep(forTimeInterval: 0.6)

        let sticky = app.staticTexts["Sticky"]
        XCTAssertTrue(sticky.waitForExistence(timeout: 3))
        sticky.doubleTap()
        Thread.sleep(forTimeInterval: 0.6)

        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("Buy milk 🥛")

        app.buttons["Done"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 0.6)

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "sticky-edited"
        shot.lifetime = .keepAlways
        add(shot)

        XCTAssertTrue(app.staticTexts["Buy milk 🥛"].waitForExistence(timeout: 3), "the sticky should show the new text")
    }
}
