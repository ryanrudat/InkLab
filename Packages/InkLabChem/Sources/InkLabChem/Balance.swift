import Foundation

public struct Term: Equatable, Sendable {
    public let formula: String
    public let coefficient: Int
    public init(_ formula: String, _ coefficient: Int) { self.formula = formula; self.coefficient = coefficient }
}

public struct BalancedEquation: Equatable, Sendable {
    public let reactants: [Term]
    public let products: [Term]
    /// Pretty form, e.g. "2 H2 + O2 -> 2 H2O".
    public var pretty: String {
        func side(_ ts: [Term]) -> String {
            ts.map { ($0.coefficient == 1 ? "" : "\($0.coefficient) ") + $0.formula }.joined(separator: " + ")
        }
        return side(reactants) + " -> " + side(products)
    }
}

public enum BalanceResult: Equatable, Sendable {
    case balanced(BalancedEquation)
    case cannotBalance(String)
    case unsupported(String)
}

/// Balance a chemical equation, e.g. "H2 + O2 -> H2O" -> "2 H2 + O2 -> 2 H2O". Solves the element
/// conservation system exactly and returns the smallest positive integer coefficients.
public func balance(_ equation: String) -> BalanceResult {
    let arrowNormalized = equation
        .replacingOccurrences(of: "→", with: "->")
        .replacingOccurrences(of: "⟶", with: "->")
        .replacingOccurrences(of: "=", with: "->")
    let sides = arrowNormalized.components(separatedBy: "->")
    guard sides.count == 2 else { return .unsupported("expected one '->' (or '=') separating reactants and products") }

    func species(_ s: String) -> [String] {
        s.components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    let reactantStrs = species(sides[0]), productStrs = species(sides[1])
    guard !reactantStrs.isEmpty, !productStrs.isEmpty else { return .unsupported("missing reactants or products") }

    let speciesStrs = reactantStrs + productStrs
    var parsed: [[String: Int]] = []
    for sp in speciesStrs {
        guard let counts = parseFormula(sp) else { return .unsupported("couldn't read formula \"\(sp)\"") }
        parsed.append(counts)
    }

    let elements = Set(parsed.flatMap { $0.keys }).sorted()
    let nSpecies = speciesStrs.count
    // Matrix: rows = elements, cols = species. Reactants positive, products negative.
    var matrix: [[Frac]] = elements.map { el in
        (0..<nSpecies).map { j in
            let count = parsed[j][el] ?? 0
            let signed = j < reactantStrs.count ? count : -count
            return Frac(signed)
        }
    }

    let basis = nullSpace(&matrix, columns: nSpecies)
    guard basis.count == 1 else {
        return .cannotBalance(basis.isEmpty ? "this equation has no balance (an element isn't conserved)"
                                            : "this equation is underdetermined (multiple independent balances)")
    }
    guard let coeffs = smallestPositiveIntegers(basis[0]) else {
        return .cannotBalance("no all-positive integer coefficients exist")
    }

    let reactantTerms = zip(reactantStrs, coeffs.prefix(reactantStrs.count)).map { Term($0, $1) }
    let productTerms = zip(productStrs, coeffs.suffix(productStrs.count)).map { Term($0, $1) }
    return .balanced(BalancedEquation(reactants: reactantTerms, products: productTerms))
}

// MARK: - Exact linear algebra

/// Reduce `m` to RREF in place and return a basis for its null space (each vector has `columns` entries).
func nullSpace(_ m: inout [[Frac]], columns: Int) -> [[Frac]] {
    let rows = m.count
    var pivotCol = [Int]()          // pivot column for each pivot row
    var r = 0
    for c in 0..<columns where r < rows {
        // find a pivot in column c at or below row r
        guard let p = (r..<rows).first(where: { !m[$0][c].isZero }) else { continue }
        m.swapAt(r, p)
        let inv = Frac(1) / m[r][c]
        m[r] = m[r].map { $0 * inv }                 // normalize pivot to 1
        for i in 0..<rows where i != r {             // eliminate the column elsewhere
            let factor = m[i][c]
            if !factor.isZero { m[i] = zip(m[i], m[r]).map { $0 - factor * $1 } }
        }
        pivotCol.append(c)
        r += 1
    }
    let pivotSet = Set(pivotCol)
    let freeCols = (0..<columns).filter { !pivotSet.contains($0) }

    return freeCols.map { f in
        var v = [Frac](repeating: .zero, count: columns)
        v[f] = Frac(1)
        for (row, pc) in pivotCol.enumerated() { v[pc] = -m[row][f] }
        return v
    }
}

/// Scale a rational null-space vector to the smallest all-positive integer vector, or nil if no
/// such vector exists (mixed signs, or a zero coefficient on a real species).
func smallestPositiveIntegers(_ v: [Frac]) -> [Int]? {
    let denomLCM = v.reduce(1) { lcm($0, $1.d) }
    var ints = v.map { $0.n * (denomLCM / $0.d) }
    if ints.allSatisfy({ $0 <= 0 }) { ints = ints.map { -$0 } }   // flip an all-negative solution
    guard ints.allSatisfy({ $0 > 0 }) else { return nil }         // any non-positive => invalid balance
    let g = ints.reduce(0) { Frac.gcd($0, abs($1)) }
    return g > 1 ? ints.map { $0 / g } : ints
}
