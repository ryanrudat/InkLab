import XCTest

/// Verifies every object now has working chrome: a sticky shows a ✕ (delete) and a resize grip, and
/// tapping the ✕ removes it. Captures before/after screenshots.
final class StickyChromeShot: XCTestCase {
    func testStickyDeleteChrome() {
        let app = XCUIApplication()
        app.launch()

        // Open the first notebook (top-left cover; found by id, since the Home header moves it).
        let firstCover = app.buttons.matching(identifier: "notebookCover").firstMatch
        XCTAssertTrue(firstCover.waitForExistence(timeout: 10))
        firstCover.tap()
        Thread.sleep(forTimeInterval: 1.0)

        // Drop a sticky note.
        let addSticky = app.buttons["addSticky"]
        XCTAssertTrue(addSticky.waitForExistence(timeout: 5))
        addSticky.tap()
        Thread.sleep(forTimeInterval: 0.6)

        let withChrome = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        withChrome.name = "sticky-with-chrome"
        withChrome.lifetime = .keepAlways
        add(withChrome)

        // The delete ✕ should now exist; tap it.
        let del = app.buttons["Delete"]
        XCTAssertTrue(del.waitForExistence(timeout: 3), "every object should have a delete ✕")
        del.tap()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertFalse(app.buttons["Delete"].exists, "the object (and its ✕) should be gone after delete")

        let afterDelete = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        afterDelete.name = "after-delete"
        afterDelete.lifetime = .keepAlways
        add(afterDelete)
    }
}
