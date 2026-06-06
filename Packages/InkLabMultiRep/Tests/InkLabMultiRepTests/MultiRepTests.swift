import XCTest
@testable import InkLabMultiRep
import InkLabFit

final class MultiRepTests: XCTestCase {

    func test_equationToTable() throws {
        let table = try XCTUnwrap(sampleFunction("x^2", from: 0, to: 4, count: 5))
        XCTAssertEqual(table.map { $0.y }, [0, 1, 4, 9, 16])
    }

    func test_equationToTable_skipsUndefinedPoints() throws {
        // 1/x is undefined at x = 0 → that sample is skipped, no crash
        let table = try XCTUnwrap(sampleFunction("1 / x", from: -1, to: 1, count: 3))
        XCTAssertFalse(table.contains { $0.x == 0 })
    }

    func test_equationToTable_rejectsMultiVariable() {
        XCTAssertNil(sampleFunction("x + y", from: 0, to: 1, count: 5))
    }

    func test_tableToEquation_picksLinear() throws {
        let pts = (0...5).map { Point2D(x: Double($0), y: 2 * Double($0) + 1) }
        XCTAssertEqual(bestFit(pts)?.kind, "linear")   // not over-fit as a cubic
    }

    func test_tableToEquation_picksQuadratic() throws {
        let pts = (-2...4).map { Point2D(x: Double($0), y: Double($0 * $0)) }
        XCTAssertEqual(bestFit(pts)?.kind, "quadratic")
    }

    func test_tableToEquation_picksExponential() throws {
        let pts = (0...5).map { Point2D(x: Double($0), y: 2 * exp(0.7 * Double($0))) }
        XCTAssertEqual(bestFit(pts)?.kind, "exponential")
    }

    func test_roundTrip_equationThroughTableBackToModel() throws {
        // y = 3x² over positive x — parsimony correctly reports it as a POWER law (y = 3·x², 2
        // params) rather than a 3-parameter quadratic; both have R² ≈ 1.
        let table = try XCTUnwrap(sampleFunction("3 * x^2", from: 1, to: 6, count: 12))
        let fit = try XCTUnwrap(bestFit(table))
        XCTAssertEqual(fit.kind, "power")
        XCTAssertGreaterThan(fit.rSquared, 0.9999)
    }

    func test_linkedRepresentation_derivesBothWays() throws {
        let fromEq = LinkedRepresentation(equation: "2*x + 1", over: 0...4, count: 5)
        XCTAssertEqual(fromEq.table?.count, 5)

        let fromTable = LinkedRepresentation(table: (0...5).map { Point2D(x: Double($0), y: 2 * Double($0) + 1) })
        XCTAssertEqual(fromTable.equation?.kind, "linear")
    }
}
