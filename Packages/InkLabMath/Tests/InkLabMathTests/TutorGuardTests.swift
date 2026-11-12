import XCTest
@testable import InkLabMath

/// The tutor's engine side: what must be protected, and the exact answer-leak check of a reply.
final class TutorGuardTests: XCTestCase {

    private func leak(_ reply: String, _ lines: [String], studentAlsoWrote: [String] = []) -> String? {
        let facts = problemFacts(lines)!
        return tutorReplyLeak(reply, protected: facts.protected, studentWrote: studentMathKeys(lines + studentAlsoWrote))
    }

    func test_factsComeFromTheProblemLine() throws {
        XCTAssertEqual(problemFacts(["2x + 3 = 7", "2x = 10"])?.chain, .equation)
        XCTAssertEqual(problemFacts(["(x+1)^2", "= x^2 + 1"])?.chain, .expression)
        XCTAssertEqual(problemFacts(["d/dx(x^3 + 2x) = 3x^2"])?.chain, .derivative)
        XCTAssertEqual(problemFacts(["∫ x^2 dx = x^3/2 + C"])?.chain, .integral)
        XCTAssertNil(problemFacts(["= 4"]))
        XCTAssertNil(problemFacts(["2x + @ = 7"]))
        // The derivative is computed exactly by the engine, never taken from the student.
        guard case .expression(let d) = problemFacts(["d/dx(x^3 + 2x) = 3x^2"])!.protected[0] else { return XCTFail() }
        XCTAssertTrue(canonicalize(d).equals(canonicalize(try parseExpr("3x^2 + 2"))))
    }

    func test_statedSolutionsAndRearrangementsAreLeaks() {
        let work = ["2x + 3 = 7", "2x = 10", "x = 5"]
        XCTAssertEqual(leak("So x = 2.", work), "x = 2")
        XCTAssertEqual(leak("Then x is 2!", work), "x = 2")
        XCTAssertEqual(leak("Line 2 should be 2x = 4.", work), "2x = 4")
        XCTAssertEqual(leak("Or write 4 = 2x.", work), "4 = 2x")
    }

    func test_quotingTheStudentAndOtherProblemsAreNotLeaks() {
        let work = ["2x + 3 = 7", "2x = 10", "x = 5"]
        XCTAssertNil(leak("You wrote 2x = 10 on line 2. How did you get that from 2x + 3 = 7?", work))
        XCTAssertNil(leak("For example, if 3y + 2 = 11, then 3y = 9 and y = 3.", work))
        XCTAssertNil(leak("Look at line 2 and line 3.", work))
    }

    func test_expressionValueIsProtectedByEquivalence() {
        let work = ["(x+1)^2", "= x^2 + 1"]
        XCTAssertNotNil(leak("It should be x² + 2x + 1.", work))
        XCTAssertNotNil(leak("It is 1 + 2x + x^2", work))
        XCTAssertNil(leak("Try x = -5 in both (x+1)^2 and x^2 + 1.", work))
    }

    func test_calculusResultsAreProtected() {
        XCTAssertNotNil(leak("The derivative is 2 + 3x^2.", ["d/dx(x^3 + 2x) = 3x^2"]))
        XCTAssertNotNil(leak("It should be x³/3 + C.", ["∫ x^2 dx = x^3/2 + C"]))
        XCTAssertNil(leak("Differentiate x^3/2 + C. Do you get back x^2?", ["∫ x^2 dx = x^3/2 + C"]))
        // A correct result the student already wrote may be quoted back.
        XCTAssertNil(leak("Yes: x^3/3 is right.", ["∫ x^2 dx = x^3/3 + C"]))
    }

    func test_contractionsAndArticlesDoNotHideALeak() {
        let work = ["d/dx(x^3 + 2x) = 3x^2"]
        XCTAssertNotNil(leak("It's 2 + 3x^2.", work))
        XCTAssertNotNil(leak("The derivative is a 3x^2 + 2 shape.", work))
        XCTAssertNotNil(leak("I'm sure it is 3x^2 + 2", work))
    }

    func test_studentRepliesCountAsTheirOwnWork() {
        let work = ["2x + 3 = 7", "2x = 10"]
        XCTAssertNotNil(leak("Yes, 2x = 4!", work))
        XCTAssertNil(leak("Yes, 2x = 4!", work, studentAlsoWrote: ["2x = 4"]))
    }

    func test_anUnfinishedLineProtectsItsValue() {
        // "1+3=" with nothing after it: the student is working out 1 + 3, so its value is the answer.
        XCTAssertEqual(problemFacts(["1+3="])?.chain, .expression)
        XCTAssertNotNil(leak("You get 4.", ["1+3="]))
        XCTAssertNotNil(leak("It's 2 + 2.", ["1+3="]))
        XCTAssertNil(leak("What do you get when you put 1 and 3 together?", ["1+3="]))
        XCTAssertNil(leak("What is 1 + 3?", ["1+3="]))
        // Once they finish it ("1+3 = 4") it is still arithmetic, not an equation to solve.
        XCTAssertEqual(problemFacts(["1+3 = 4"])?.chain, .expression)
        XCTAssertEqual(problemFacts(["2x + 3 = 7", "2x ="])?.chain, .equation)
        XCTAssertEqual(problemFacts(["d/dx(x^2) ="])?.chain, .derivative)
        XCTAssertEqual(problemFacts(["∫ x dx ="])?.chain, .integral)
    }

    func test_finishingAnUnfinishedLine() {
        XCTAssertEqual(completingUnfinished("1+3=", with: "4"), "1+3 = 4")
        XCTAssertEqual(completingUnfinished("1+3 =", with: "= 4"), "1+3 = 4")
        XCTAssertEqual(completingUnfinished("1+3=", with: "1 + 3 = 4"), "1 + 3 = 4")
        XCTAssertEqual(completingUnfinished("= 7", with: "2x + 3"), "2x + 3 = 7")
        XCTAssertEqual(completingUnfinished("=", with: "4"), "4")
    }

    func test_asciiRenderingRoundTripsThroughTheParser() throws {
        for s in ["(x+1)^2", "-x/2 + 3/4", "2x·(x − 1)", "sin(x)^2", "x^(-1)"] {
            let e = try parseExpr(s.replacingOccurrences(of: "·", with: "*").replacingOccurrences(of: "−", with: "-"))
            let back = try parseExpr(XCTUnwrap(renderTutorASCII(e)))
            XCTAssertTrue(canonicalize(back).equals(canonicalize(e)), s)
        }
        XCTAssertNil(renderTutorASCII(.funcApp("∂", [.variable("x")])))
    }
}
