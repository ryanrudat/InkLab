import XCTest

/// The Socratic tutor end to end, against the local mock proxy (`cd Server && npm run mock`): the real
/// server — consent gate, hint ladder, answer-leak guard — with a scripted stand-in for Claude whose first
/// draft leaks the answer. Write working → ＋ → Tutor → ONE margin note beside line 2 (never the leaked
/// draft) → write a corrected step next to the problem → it's read, checked by the engine and answered in
/// the same note, the earlier messages folded into "N earlier" → Another hint → a typed question → undo
/// rewinds one message → ✕ closes the session, undo brings it back. Screenshots at each step.
///
/// Skipped unless the mock is running, so the regular UI test run is unaffected.
final class TutorFlowShot: XCTestCase {
    /// The mock by default; `TEST_RUNNER_TUTOR_PROXY=http://localhost:8790 xcodebuild test …` runs the same
    /// flow against a live proxy (real model, stubbed reading), skipping the mock-only wording checks.
    private let proxy = ProcessInfo.processInfo.environment["TUTOR_PROXY"] ?? "http://localhost:8799"
    private var isMock: Bool { proxy.hasSuffix(":8799") }

    private func shot(_ name: String) {
        let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    private func stroke(_ app: XCUIApplication, from a: CGPoint, to b: CGPoint) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: a.x, dy: a.y))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: b.x, dy: b.y)))
    }

    private func debugDump(_ app: XCUIApplication, _ name: String) {
        let att = XCTAttachment(string: app.debugDescription)
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    /// Wait until `element`'s label satisfies `test`.
    private func waitLabel(_ element: XCUIElement, timeout: TimeInterval = 30, _ test: @escaping (String) -> Bool) -> Bool {
        let p = NSPredicate { obj, _ in (obj as? XCUIElement).map { $0.exists && test($0.label) } ?? false }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: p, object: element)], timeout: timeout) == .completed
    }

    /// Launch against the proxy with the AI permission on, in a fresh notebook (no existing one is touched).
    @MainActor
    private func launchIntoNewNotebook() throws -> XCUIApplication {
        let up = expectation(description: "mock proxy")
        var reachable = false
        URLSession.shared.dataTask(with: URL(string: "\(proxy)/health")!) { _, resp, _ in
            reachable = (resp as? HTTPURLResponse)?.statusCode == 200
            up.fulfill()
        }.resume()
        wait(for: [up], timeout: 5)
        try XCTSkipUnless(reachable, "Start the mock proxy first: cd Server && npm run mock")

        let app = XCUIApplication()
        app.launchEnvironment["INKLAB_TEST_STORE"] = "1"   // a throwaway library, never the real notebooks
        app.launchEnvironment["INKLAB_PROXY_URL"] = proxy
        app.launch()

        // The tutor talks through the proxy, so the AI permission must be on (it isn't persisted).
        let settings = app.buttons["settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        let consent = app.switches["Allow AI generation"]
        for _ in 0..<3 where !consent.exists { settings.tap(); _ = consent.waitForExistence(timeout: 3) }   // a tap during launch can be dropped
        XCTAssertTrue(consent.exists)
        if consent.value as? String != "1" { consent.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        XCTAssertEqual(consent.value as? String, "1", "couldn't turn on the AI permission")
        app.buttons["Done"].tap()

        // A fresh notebook, so no existing notebook is touched.
        app.buttons["newNotebook"].tap()
        let covers = app.buttons.matching(NSPredicate(format: "label == 'Untitled'"))
        XCTAssertTrue(covers.firstMatch.waitForExistence(timeout: 5))
        covers.element(boundBy: covers.count - 1).tap()
        XCTAssertTrue(app.buttons["insertMenu"].waitForExistence(timeout: 5))

        return app
    }

    /// The bug from the theme pass: with a calculator in the middle of the page and the working to its left,
    /// the note used to land on the calculator's keys (sometimes drawn above it, sometimes below).
    @MainActor
    func testNoteNeverCoversAWidget() throws {
        let app = try launchIntoNewNotebook()
        app.buttons["insertMenu"].tap()
        app.buttons["insertCalculator"].tap()
        let keys = ["7", "4", "1", "divide", "minus"].map { app.buttons[$0] }
        XCTAssertTrue(keys[0].waitForExistence(timeout: 5))
        for (i, width) in [180.0, 120.0, 90.0].enumerated() {
            let y = 640.0 + Double(i) * 50
            stroke(app, from: CGPoint(x: 60, y: y), to: CGPoint(x: 60 + width, y: y + 6))
        }
        app.buttons["insertMenu"].tap()
        app.buttons["tutor"].tap()
        let note = app.otherElements["tutorNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 30))
        shot("widget-avoided")
        for key in keys { XCTAssertFalse(note.frame.intersects(key.frame), "the note covers the calculator's \(key.label) key") }
        let calculator = keys.dropFirst().reduce(keys[0].frame) { $0.union($1.frame) }
        XCTAssertFalse(note.frame.intersects(calculator), "the note overlaps the calculator: \(note.frame) vs \(calculator)")
    }

    @MainActor
    func testTutorConversation() throws {
        let app = try launchIntoNewNotebook()

        // Three lines of "working" (the mock reads them as 2x + 3 = 7 / 2x = 10 / x = 5).
        for (i, width) in [180.0, 120.0, 90.0].enumerated() {
            let y = 300.0 + Double(i) * 50
            stroke(app, from: CGPoint(x: 60, y: y), to: CGPoint(x: 60 + width, y: y + 6))
        }

        // ＋ → Tutor: one note in the margin beside line 2. The mock's first draft ("…you get x = 2")
        // must have been rejected by the proxy's guard.
        app.buttons["insertMenu"].tap()
        app.buttons["tutor"].tap()
        let message = app.staticTexts["tutorMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 30), "the tutor's first message never appeared")
        XCTAssertFalse(message.label.contains("x = 2"), "the leaked draft reached the page: \(message.label)")
        XCTAssertTrue(app.staticTexts["tutorHeader"].label.contains("hint 1 of 4"))
        let note = app.otherElements["tutorNote"]
        XCTAssertGreaterThan(note.frame.minX, 60 + 180, "the note must sit right of the working, not on it")
        XCTAssertEqual(app.otherElements.matching(identifier: "tutorNote").count, 1)
        let first = message.label
        shot("1-first-hint")

        // A corrected step written next to the problem: read (mock: "2x = 4"), checked by the red pen,
        // answered in the SAME note; the earlier messages fold into "2 earlier".
        stroke(app, from: CGPoint(x: 60, y: 470), to: CGPoint(x: 150, y: 476))
        XCTAssertTrue(waitLabel(message) { $0 != first && (!self.isMock || $0.contains("Nice fix to line 2")) }, "the written reply was never answered")
        XCTAssertEqual(app.otherElements.matching(identifier: "tutorNote").count, 1, "one note per session, not one card per message")
        let earlier = app.buttons["tutorEarlier"]
        XCTAssertTrue(earlier.label.contains("2 earlier"), earlier.label)
        earlier.tap()
        let fixRow = app.staticTexts.matching(NSPredicate(format: "identifier == 'tutorThread' AND label CONTAINS 'You: 2x = 4'")).firstMatch
        if !fixRow.waitForExistence(timeout: 5) { debugDump(app, "thread-rows") }
        XCTAssertTrue(fixRow.exists && fixRow.label.contains("checks out"), "the engine's check isn't in the thread")
        shot("2-written-fix-thread-expanded")
        earlier.tap()   // fold it again
        XCTAssertTrue(waitLabel(earlier, timeout: 5) { $0.contains("2 earlier") })

        // Reply → Another hint (the ladder climbs only because the student asked).
        app.buttons["tutorReply"].tap()
        if !app.alerts.firstMatch.waitForExistence(timeout: 5) { debugDump(app, "after-reply-tap") }
        XCTAssertTrue(app.alerts.buttons["Another hint"].waitForExistence(timeout: 5))
        app.alerts.buttons["Another hint"].tap()
        XCTAssertTrue(waitLabel(app.staticTexts["tutorHeader"]) { $0.contains("hint 2 of 4") })
        let second = message.label
        shot("3-another-hint")

        // A typed QUESTION: checked by the engine but not added to the working, and no ladder reset.
        app.buttons["tutorReply"].tap()
        let field = app.alerts.textFields["tutorReplyField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("so is x = 2?")
        app.alerts.buttons["Send"].tap()
        XCTAssertTrue(waitLabel(app.buttons["tutorEarlier"]) { $0.contains("6 earlier") })
        XCTAssertTrue(app.staticTexts["tutorHeader"].label.contains("hint 2 of 4"))
        shot("4-typed-question")

        // Undo rewinds the conversation by one tutor message (same note).
        app.buttons["undo"].tap()
        XCTAssertTrue(waitLabel(message, timeout: 5) { $0 == second })
        shot("5-after-undo")

        // ✕ closes the whole session; undo brings it back.
        app.buttons["tutorClose"].tap()
        XCTAssertTrue(note.waitForNonExistence(timeout: 5))
        app.buttons["undo"].tap()
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        shot("6-closed-then-undone")
    }
}
