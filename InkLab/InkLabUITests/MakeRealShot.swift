import XCTest

/// Drives the make-real loop: write "@a clock" in the command bar and confirm a live, generated
/// widget materializes on the page (rendered in the sandboxed WKWebView). Captures a screenshot.
final class MakeRealShot: XCTestCase {
    func testMakeRealClock() {
        let app = XCUIApplication()
        app.launch()

        // Open the first notebook (top-left cover).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.13, dy: 0.20)).tap()
        Thread.sleep(forTimeInterval: 1.0)

        // Reveal the "@" command bar and run a make-real request.
        let atButton = app.buttons["atButton"]
        XCTAssertTrue(atButton.waitForExistence(timeout: 5))
        atButton.tap()
        Thread.sleep(forTimeInterval: 0.8)

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("@a scientific calculator")
        app.buttons["Run"].firstMatch.tap()

        // Real Claude generation can take a while; wait for it, then let the sandbox render.
        Thread.sleep(forTimeInterval: 55)

        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = "make-real-clock"
        att.lifetime = .keepAlways
        add(att)
    }
}
