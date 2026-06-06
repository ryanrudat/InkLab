import XCTest
@testable import InkLabRouter
import InkLabRecognition

final class RouterTests: XCTestCase {

    // MARK: - @ ask-marker parsing

    func test_parsesDeterministicVerbs() {
        XCTAssertEqual(parseCommand("@solve"), .solve)
        XCTAssertEqual(parseCommand("solve"), .solve)                  // @ is optional
        XCTAssertEqual(parseCommand("@graph y = x^2"), .graph)
        XCTAssertEqual(parseCommand("@balance H2 + O2 -> H2O"), .balance)
        XCTAssertEqual(parseCommand("@integrate"), .integrate)
    }

    func test_parsesNativeCalculator() {
        XCTAssertEqual(parseCommand("@scientific calculator"), .scientificCalculator)
        XCTAssertEqual(parseCommand("@calc"), .scientificCalculator)
    }

    func test_parsesQuizTopic() {
        XCTAssertEqual(parseCommand("@quiz me on Biology"), .quiz("Biology"))
        XCTAssertEqual(parseCommand("@quiz about cells"), .quiz("cells"))
    }

    func test_parsesAnimateAndMakeReal() {
        XCTAssertEqual(parseCommand("@animate photosynthesis"), .animate("photosynthesis"))
        XCTAssertEqual(parseCommand("@make a working volcano"), .makeReal("a working volcano"))
    }

    func test_questionsBecomeExplain() {
        XCTAssertEqual(parseCommand("@why does ice float"), .explain("why does ice float"))
        XCTAssertEqual(parseCommand("@is this prime?"), .explain("is this prime?"))
    }

    func test_unmatchedFallsBackToMakeReal() {
        XCTAssertEqual(parseCommand("@a spinning galaxy"), .makeReal("a spinning galaxy"))
    }

    // MARK: - dispatch (§4.3 reliability pattern)

    func test_knownIntentsGoToDeterministicEngines() {
        XCTAssertEqual(dispatch(for: .solve), .deterministic(engine: "InkLabMath", action: "solve"))
        XCTAssertEqual(dispatch(for: .balance), .deterministic(engine: "InkLabChem", action: "balance"))
        XCTAssertEqual(dispatch(for: .punnett), .deterministic(engine: "InkLabBio", action: "punnett"))
    }

    func test_calculatorIsNative_makeRealIsGenerative() {
        XCTAssertEqual(dispatch(for: .scientificCalculator), .native(widget: "scientificCalculator"))
        XCTAssertEqual(dispatch(for: .makeReal("a clock")), .generative(prompt: "a clock"))
    }

    // MARK: - action chips for a recognized selection

    func test_mathSelectionOffersSolveAndGraph() {
        let chips = actionChips(for: .latex("x^2 + 3x"), domain: .math)
        XCTAssertTrue(chips.contains(.solve))
        XCTAssertTrue(chips.contains(.graph))
        XCTAssertTrue(chips.contains(.checkWork))
    }

    func test_chemistrySelectionOffersMolarMass() {
        XCTAssertEqual(actionChips(for: .smiles("CCO"), domain: .chemistry), [.molarMass])
    }

    func test_plainTextOffersNoChips() {
        XCTAssertTrue(actionChips(for: .plainText("hello"), domain: .text).isEmpty)
    }
}
