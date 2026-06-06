import XCTest
@testable import InkLabFit

final class FitTests: XCTestCase {

    func pts(_ f: (Double) -> Double, _ xs: [Double]) -> [Point2D] { xs.map { Point2D(x: $0, y: f($0)) } }

    func test_linearFit_exact() throws {
        let fit = try XCTUnwrap(linearFit(pts({ 2 * $0 + 1 }, [0, 1, 2, 3, 4])))
        XCTAssertEqual(fit.slope, 2, accuracy: 1e-9)
        XCTAssertEqual(fit.intercept, 1, accuracy: 1e-9)
        XCTAssertEqual(fit.rSquared, 1, accuracy: 1e-9)
        XCTAssertEqual(fit.predict(10), 21, accuracy: 1e-9)
    }

    func test_linearFit_noisy_hasErrorBars() throws {
        let data = [Point2D(x: 0, y: 0.1), Point2D(x: 1, y: 1.9), Point2D(x: 2, y: 4.2),
                    Point2D(x: 3, y: 5.9), Point2D(x: 4, y: 8.1)]
        let fit = try XCTUnwrap(linearFit(data))
        XCTAssertEqual(fit.slope, 2, accuracy: 0.2)        // ≈ slope 2
        XCTAssertGreaterThan(fit.rSquared, 0.99)
        XCTAssertGreaterThan(fit.slopeStdError, 0)         // real error bar
        XCTAssertLessThan(fit.rSquared, 1.0 + 1e-9)
    }

    func test_polynomialFit_quadraticExact() throws {
        // y = x² − 3x + 2  → coefficients [2, −3, 1]
        let fit = try XCTUnwrap(polynomialFit(pts({ $0 * $0 - 3 * $0 + 2 }, [-1, 0, 1, 2, 3, 4]), degree: 2))
        XCTAssertEqual(fit.coefficients.count, 3)
        XCTAssertEqual(fit.coefficients[0], 2, accuracy: 1e-6)
        XCTAssertEqual(fit.coefficients[1], -3, accuracy: 1e-6)
        XCTAssertEqual(fit.coefficients[2], 1, accuracy: 1e-6)
        XCTAssertEqual(fit.rSquared, 1, accuracy: 1e-9)
    }

    func test_exponentialFit() throws {
        let fit = try XCTUnwrap(exponentialFit(pts({ 2 * exp(0.5 * $0) }, [0, 1, 2, 3, 4])))
        XCTAssertEqual(fit.a, 2, accuracy: 1e-6)
        XCTAssertEqual(fit.b, 0.5, accuracy: 1e-6)
        XCTAssertEqual(fit.rSquared, 1, accuracy: 1e-6)
    }

    func test_powerFit() throws {
        let fit = try XCTUnwrap(powerFit(pts({ 3 * pow($0, 2) }, [1, 2, 3, 4, 5])))
        XCTAssertEqual(fit.a, 3, accuracy: 1e-6)
        XCTAssertEqual(fit.b, 2, accuracy: 1e-6)
        XCTAssertEqual(fit.rSquared, 1, accuracy: 1e-6)
    }

    func test_degenerateInputsReturnNil() {
        XCTAssertNil(linearFit([Point2D(x: 1, y: 1)]))                       // < 2 points
        XCTAssertNil(linearFit([Point2D(x: 5, y: 1), Point2D(x: 5, y: 9)]))  // all x equal
        XCTAssertNil(polynomialFit(pts({ $0 }, [0, 1]), degree: 2))          // too few points for degree
        XCTAssertNil(exponentialFit([Point2D(x: 0, y: -1), Point2D(x: 1, y: 2)]))  // non-positive y
    }
}
