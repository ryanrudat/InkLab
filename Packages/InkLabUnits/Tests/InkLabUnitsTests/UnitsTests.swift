import XCTest
@testable import InkLabUnits

final class UnitsTests: XCTestCase {

    // MARK: - Dimension algebra & the registry

    func test_derivedDimensionsCompose() {
        XCTAssertEqual(Dimension.force, Dimension.mass * Dimension.acceleration)
        XCTAssertEqual(Dimension.energy, Dimension.force * Dimension.length)
        XCTAssertEqual(Dimension.power, Dimension.energy / Dimension.time)
    }

    func test_parseUnits_andPrefixes() {
        XCTAssertEqual(dimensionOf("N"), .force)
        XCTAssertEqual(dimensionOf("kg m / s^2"), .force)
        XCTAssertEqual(dimensionOf("m/s"), .velocity)
        XCTAssertEqual(dimensionOf("km"), .length)
        XCTAssertEqual(Units.symbol("km")?.1, 1000)         // prefix scale
        XCTAssertEqual(Units.symbol("ms")?.1, 1e-3)         // milli + second
        XCTAssertEqual(Units.symbol("min")?.1, 60)          // whole symbol beats prefix split
    }

    func test_unitsEqual() {
        XCTAssertTrue(unitsEqual("N", "kg m / s^2"))
        XCTAssertTrue(unitsEqual("J", "N m"))
        XCTAssertTrue(unitsEqual("W", "J/s"))
        XCTAssertFalse(unitsEqual("J", "W"))
        XCTAssertFalse(unitsEqual("m", "s"))
    }

    // MARK: - Dimensional analysis of formulas

    func test_kinematicsFormulaIsLength() {
        let env = ["a": Dimension.acceleration, "t": Dimension.time]
        XCTAssertEqual(checkExpression("1/2 a t^2", env: env), .consistent(.length))
    }

    func test_addingIncompatibleUnitsIsFlagged() {
        guard case .mismatch(let msg) = checkExpression("5 m + 3 s") else { return XCTFail("expected a mismatch") }
        XCTAssertTrue(msg.contains("m") && msg.contains("s"))
    }

    func test_equationConsistency() {
        let env = ["F": Dimension.force, "m": Dimension.mass, "a": Dimension.acceleration, "t": Dimension.time]
        XCTAssertEqual(checkEquation("F = m a", env: env), .consistent(.force))
        guard case .mismatch = checkEquation("F = m a t", env: env) else { return XCTFail("expected a mismatch") }
    }

    func test_functionArgumentsMustBeDimensionless() {
        XCTAssertEqual(checkExpression("sin(x)", env: ["x": .dimensionless]), .consistent(.dimensionless))
        guard case .mismatch = checkExpression("sin(t)", env: ["t": .time]) else { return XCTFail("expected a mismatch") }
    }

    func test_sqrtOfAreaIsLength() {
        XCTAssertEqual(checkExpression("sqrt(A)", env: ["A": .area]), .consistent(.length))
        guard case .mismatch = checkExpression("sqrt(t)", env: ["t": .time]) else { return XCTFail("odd dimension can't be square-rooted") }
    }

    func test_unknownSymbolIsUnsupported() {
        guard case .unsupported = checkExpression("foo + 1") else { return XCTFail("expected unsupported") }
    }
}
