import XCTest
@testable import InkLabChem

final class ChemTests: XCTestCase {

    // MARK: - Formula parsing & molar mass

    func test_parseFormula_countsAndParentheses() {
        XCTAssertEqual(parseFormula("H2O"), ["H": 2, "O": 1])
        XCTAssertEqual(parseFormula("Ca(OH)2"), ["Ca": 1, "O": 2, "H": 2])
        XCTAssertEqual(parseFormula("C6H12O6"), ["C": 6, "H": 12, "O": 6])
        XCTAssertEqual(parseFormula("Fe2O3"), ["Fe": 2, "O": 3])
        XCTAssertEqual(parseFormula("Al2(SO4)3"), ["Al": 2, "S": 3, "O": 12])
        XCTAssertNil(parseFormula("Xx2"))      // unknown element
    }

    func test_molarMass() throws {
        XCTAssertEqual(try XCTUnwrap(molarMass("H2O")), 18.015, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(molarMass("CO2")), 44.009, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(molarMass("C6H12O6")), 180.156, accuracy: 0.01)
        XCTAssertNil(molarMass("Zz"))
    }

    // MARK: - Equation balancing (exact linear algebra)

    func balanced(_ eq: String) -> BalancedEquation? {
        if case .balanced(let b) = balance(eq) { return b }
        return nil
    }

    func test_balance_water() {
        XCTAssertEqual(balanced("H2 + O2 -> H2O")?.pretty, "2 H2 + O2 -> 2 H2O")
    }

    func test_balance_rust() {
        XCTAssertEqual(balanced("Fe + O2 -> Fe2O3")?.pretty, "4 Fe + 3 O2 -> 2 Fe2O3")
    }

    func test_balance_propaneCombustion() {
        XCTAssertEqual(balanced("C3H8 + O2 -> CO2 + H2O")?.pretty, "C3H8 + 5 O2 -> 3 CO2 + 4 H2O")
    }

    func test_balance_photosynthesis() {
        XCTAssertEqual(balanced("CO2 + H2O -> C6H12O6 + O2")?.pretty, "6 CO2 + 6 H2O -> C6H12O6 + 6 O2")
    }

    func test_balance_acceptsAlreadyBalanced() {
        // already balanced stays balanced (smallest integers => coefficients of 1)
        XCTAssertEqual(balanced("Na + Cl -> NaCl")?.pretty, "Na + Cl -> NaCl")
    }

    func test_balance_impossibleEquationIsReported() {
        guard case .cannotBalance = balance("H2 -> O2") else { return XCTFail("an unbalanceable equation must be reported") }
    }

    func test_balance_badFormulaIsUnsupported() {
        guard case .unsupported = balance("H2 + Qz -> H2O") else { return XCTFail("unknown element should be unsupported") }
    }
}
