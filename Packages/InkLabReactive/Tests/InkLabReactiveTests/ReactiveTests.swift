import XCTest
@testable import InkLabReactive

final class ReactiveTests: XCTestCase {

    func values(_ g: ReactiveGraph) -> [String: Double]? {
        if case .success(let v) = g.evaluate() { return v }
        return nil
    }

    func test_basicRecompute() throws {
        let g = ReactiveGraph()
        g.setInput("a", 2)
        g.setInput("b", 3)
        try g.setFormula("c", "a + b")
        XCTAssertEqual(values(g)?["c"], 5)
    }

    /// Regression: a mathematically-undefined cell must report `.undefined`, NOT `.success` with a NaN.
    /// (numericValue used to return a non-nil NaN for (-2)^0.5, which passed the guard and silently
    /// poisoned the whole sheet.)
    func test_undefinedResultDoesNotSucceedWithNaN() throws {
        let g = ReactiveGraph()
        g.setInput("x", -2)
        try g.setFormula("y", "x^0.5")          // (-2)^0.5 is undefined over the reals
        if case .failure = g.evaluate() {} else { XCTFail("undefined math must be .failure, not .success(NaN)") }
        // And a downstream cell isn't silently filled with NaN.
        XCTAssertNil(values(g)?["y"])
    }

    func test_changingAKnobUpdatesDownstream() throws {
        let g = ReactiveGraph()
        g.setInput("a", 2)
        try g.setFormula("b", "a * 2")
        try g.setFormula("c", "b + 1")
        XCTAssertEqual(values(g)?["c"], 5)      // (2*2)+1
        g.setInput("a", 10)                     // turn the knob
        XCTAssertEqual(values(g)?["c"], 21)     // (10*2)+1 — propagates through b
    }

    func test_formulaWithFunctionAndPower() throws {
        let g = ReactiveGraph()
        g.setInput("r", 2)
        try g.setFormula("area", "3.14159 * r^2")
        XCTAssertEqual(try XCTUnwrap(values(g)?["area"]), 12.56636, accuracy: 1e-5)
        g.setInput("r", 3)
        XCTAssertEqual(try XCTUnwrap(values(g)?["area"]), 28.27431, accuracy: 1e-5)
    }

    func test_longerChainOrderIndependent() throws {
        let g = ReactiveGraph()
        // define dependents BEFORE their inputs to prove dependency ordering, not insertion order
        try g.setFormula("z", "y + 1")
        try g.setFormula("y", "x * x")
        g.setInput("x", 4)
        XCTAssertEqual(values(g)?["z"], 17)     // (4*4)+1
    }

    func test_cycleIsDetected() throws {
        let g = ReactiveGraph()
        try g.setFormula("a", "b + 1")
        try g.setFormula("b", "a + 1")
        guard case .failure(.cycle(let names)) = g.evaluate() else { return XCTFail("expected a cycle") }
        XCTAssertTrue(names.contains("a") && names.contains("b"))
    }

    func test_undefinedReferenceIsReported() throws {
        let g = ReactiveGraph()
        try g.setFormula("c", "x + 1")          // x was never defined
        guard case .failure(.undefined(let name)) = g.evaluate() else { return XCTFail("expected undefined") }
        XCTAssertEqual(name, "x")
    }

    func test_divisionByZeroIsUndefined() throws {
        let g = ReactiveGraph()
        g.setInput("n", 1)
        g.setInput("d", 0)
        try g.setFormula("q", "n / d")
        guard case .failure(.undefined(let name)) = g.evaluate() else { return XCTFail("expected undefined") }
        XCTAssertEqual(name, "q")
    }

    func test_parseErrorSurfaces() {
        let g = ReactiveGraph()
        XCTAssertThrowsError(try g.setFormula("bad", "2 +"))
    }

    func test_multiLetterVariableNames() throws {
        // spreadsheet-style names must be whole words, not products of letters
        let g = ReactiveGraph()
        g.setInput("price", 20); g.setInput("qty", 3); g.setInput("taxRate", 0.08)
        try g.setFormula("subtotal", "price * qty")
        try g.setFormula("total", "subtotal * (1 + taxRate)")
        XCTAssertEqual(values(g)?["subtotal"], 60)
        XCTAssertEqual(try XCTUnwrap(values(g)?["total"]), 64.8, accuracy: 1e-9)
    }
}
