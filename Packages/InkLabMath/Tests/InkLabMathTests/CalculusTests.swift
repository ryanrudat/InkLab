import XCTest
@testable import InkLabMath

final class CalculusTests: XCTestCase {

    // MARK: - Differentiation as exact algebra

    func test_derivative_polynomial() throws {
        XCTAssertTrue(try areEquivalent("d/dx(x^2 + 3x)", "2x + 3"))
        XCTAssertTrue(try areEquivalent("d/dx(x^3)", "3x^2"))
        XCTAssertTrue(try areEquivalent("d/dx(5)", "0"))
    }

    func test_derivative_productAndChainAndTrig() throws {
        XCTAssertTrue(try areEquivalent("d/dx(x sin(x))", "sin(x) + x cos(x)"))   // product rule
        XCTAssertTrue(try areEquivalent("d/dx(sin(x^2))", "cos(x^2) * 2x"))       // chain rule
        XCTAssertTrue(try areEquivalent("d/dx(exp(x))", "exp(x)"))
    }

    // MARK: - The tutor on derivative steps

    func test_tutor_derivative_valid_oneAndTwoLine() {
        XCTAssertEqual(checkChain(["d/dx(x^2 + 3x)", "= 2x + 3"]), .allValid(steps: 2))
        XCTAssertEqual(checkChain(["d/dx(x^3) = 3x^2"]), .allValid(steps: 1))
    }

    func test_tutor_derivative_catchesError() {
        let v = checkChain(["d/dx(x^2)", "= x"])     // forgot the factor of 2
        guard case .firstError(let line, let kind, _, let counter) = v else { return XCTFail("expected error, got \(v)") }
        XCTAssertEqual(line, 2)
        XCTAssertEqual(kind, .notEqual)
        XCTAssertNotNil(counter)
    }

    // MARK: - The tutor on integral steps (verified by differentiating the answer)

    func test_tutor_integral_valid_twoLineWithConstant() {
        XCTAssertEqual(checkChain(["∫ (2x + 3) dx", "= x^2 + 3x + C"]), .allValid(steps: 2))
    }

    func test_tutor_integral_valid_oneLine() {
        XCTAssertEqual(checkChain(["∫ 2x dx = x^2 + C"]), .allValid(steps: 1))
        XCTAssertEqual(checkChain(["∫ cos(x) dx = sin(x) + C"]), .allValid(steps: 1))
    }

    func test_tutor_integral_catchesError() {
        let v = checkChain(["∫ 2x dx", "= x^2 + x"])    // wrong antiderivative
        guard case .firstError(let line, let kind, _, _) = v else { return XCTFail("expected error, got \(v)") }
        XCTAssertEqual(line, 2)
        XCTAssertEqual(kind, .notEqual)
    }

    func test_tutor_integral_powerRule() {
        // ∫ x^2 dx = x^3/3 + C  — exact rational coefficient, verified by differentiation
        XCTAssertEqual(checkChain(["∫ x^2 dx = x^3/3 + C"]), .allValid(steps: 1))
        // a wrong coefficient is caught
        guard case .firstError = checkChain(["∫ x^2 dx = x^3/2 + C"]) else { return XCTFail("expected error") }
    }
}
