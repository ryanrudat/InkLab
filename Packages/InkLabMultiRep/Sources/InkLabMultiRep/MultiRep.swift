import Foundation
import InkLabMath
import InkLabFit

// MARK: - Equation → table

/// Sample a single-variable function over [from, to] into a table of points (the equation→table
/// link). Points where the function is undefined (e.g. an asymptote) are skipped. Returns nil if the
/// formula doesn't parse or uses more than one variable.
public func sampleFunction(_ formula: String, from a: Double, to b: Double, count: Int = 50) -> [Point2D]? {
    guard count >= 2, let expr = try? parseExpr(formula) else { return nil }
    let vars = variables(in: expr)
    guard vars.count <= 1 else { return nil }
    let v = vars.first ?? "x"
    var points: [Point2D] = []
    for i in 0..<count {
        let x = a + (b - a) * Double(i) / Double(count - 1)
        // Skip undefined/non-finite points (asymptotes, NaN from an undefined domain) so a NaN never
        // enters the table and poisons the downstream best-fit (numericValue is already finite-or-nil;
        // the explicit isFinite is belt-and-suspenders).
        if let y = numericValue(expr, [v: x]), y.isFinite { points.append(Point2D(x: x, y: y)) }
    }
    return points.isEmpty ? nil : points
}

// MARK: - Table → equation (best-fit model)

public struct FitSummary: Equatable, Sendable {
    public let kind: String        // "linear" / "quadratic" / "cubic" / "exponential" / "power"
    public let rSquared: Double
    public let equation: String    // human-readable, e.g. "y = 2.000·x + 1.000"
}

/// Pick the best-fitting model for a table (the table→equation link). Among candidates it maximizes
/// R², breaking ties toward the simpler model (fewer parameters) so a straight line isn't reported
/// as a cubic.
public func bestFit(_ points: [Point2D]) -> FitSummary? {
    var candidates: [(FitSummary, complexity: Int)] = []
    if let f = linearFit(points) {
        candidates.append((FitSummary(kind: "linear", rSquared: f.rSquared,
                                      equation: String(format: "y = %.3f·x + %.3f", f.slope, f.intercept)), 2))
    }
    if let f = exponentialFit(points) {
        candidates.append((FitSummary(kind: "exponential", rSquared: f.rSquared,
                                      equation: String(format: "y = %.3f·e^(%.3f·x)", f.a, f.b)), 2))
    }
    if let f = powerFit(points) {
        candidates.append((FitSummary(kind: "power", rSquared: f.rSquared,
                                      equation: String(format: "y = %.3f·x^%.3f", f.a, f.b)), 2))
    }
    if let f = polynomialFit(points, degree: 2) {
        candidates.append((FitSummary(kind: "quadratic", rSquared: f.rSquared, equation: polyString(f.coefficients)), 3))
    }
    if let f = polynomialFit(points, degree: 3) {
        candidates.append((FitSummary(kind: "cubic", rSquared: f.rSquared, equation: polyString(f.coefficients)), 4))
    }
    // Disqualify any candidate whose R² is non-finite: NaN compares false to everything, so leaving it
    // in would let it survive the sort and be returned as "best" purely by ordering.
    let best = candidates.filter { $0.0.rSquared.isFinite }.sorted { lhs, rhs in
        if abs(lhs.0.rSquared - rhs.0.rSquared) > 1e-6 { return lhs.0.rSquared > rhs.0.rSquared }
        return lhs.complexity < rhs.complexity   // tie → prefer the simpler model
    }.first
    return best?.0
}

private func polyString(_ c: [Double]) -> String {
    let names = ["", "·x", "·x²", "·x³"]
    let terms = c.enumerated().reversed().map { i, ci in String(format: "%.3f", ci) + (i < names.count ? names[i] : "·x^\(i)") }
    return "y = " + terms.joined(separator: " + ")
}

// MARK: - A small coordinator keeping the two representations in sync

/// Holds either an equation or a table as the source of truth, and derives the other on demand —
/// the spine of "edit one representation, the others update".
public struct LinkedRepresentation: Sendable {
    public enum Source: Sendable { case equation(String); case table([Point2D]) }
    public var source: Source
    public var sampleRange: ClosedRange<Double>
    public var sampleCount: Int

    public init(equation: String, over range: ClosedRange<Double> = -10...10, count: Int = 50) {
        source = .equation(equation); sampleRange = range; sampleCount = count
    }
    public init(table: [Point2D]) {
        source = .table(table); sampleRange = -10...10; sampleCount = 50
    }

    /// The table form (derived from the equation if needed).
    public var table: [Point2D]? {
        switch source {
        case .table(let t): return t
        case .equation(let f): return sampleFunction(f, from: sampleRange.lowerBound, to: sampleRange.upperBound, count: sampleCount)
        }
    }
    /// The equation form (a best-fit summary if the source is a table).
    public var equation: FitSummary? {
        switch source {
        case .equation(let f): return FitSummary(kind: "given", rSquared: 1, equation: "y = \(f)")
        case .table(let t): return bestFit(t)
        }
    }
}
