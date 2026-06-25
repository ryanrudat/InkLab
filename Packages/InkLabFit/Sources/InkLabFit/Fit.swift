import Foundation

public struct Point2D: Equatable, Sendable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

// MARK: - Fit results

public struct LinearFit: Equatable, Sendable {
    public let slope: Double, intercept: Double, rSquared: Double
    public let slopeStdError: Double, interceptStdError: Double
    public func predict(_ x: Double) -> Double { slope * x + intercept }
}

public struct PolyFit: Equatable, Sendable {
    public let coefficients: [Double]   // c0 + c1·x + c2·x² + …
    public let rSquared: Double
    public func predict(_ x: Double) -> Double {
        var r = 0.0
        for (i, c) in coefficients.enumerated() { r += c * pow(x, Double(i)) }
        return r
    }
}

public struct ExpFit: Equatable, Sendable {   // y = a·e^(b·x)
    public let a: Double, b: Double, rSquared: Double
    public func predict(_ x: Double) -> Double { a * exp(b * x) }
}

public struct PowerFit: Equatable, Sendable {  // y = a·x^b
    public let a: Double, b: Double, rSquared: Double
    public func predict(_ x: Double) -> Double { a * pow(x, b) }
}

// MARK: - Goodness of fit

/// Coefficient of determination R² for arbitrary predictions.
public func rSquared(_ points: [Point2D], predict: (Double) -> Double) -> Double {
    guard !points.isEmpty else { return 0 }
    let yBar = points.reduce(0) { $0 + $1.y } / Double(points.count)
    var ssRes = 0.0, ssTot = 0.0
    for p in points {
        let e = p.y - predict(p.x); ssRes += e * e
        let d = p.y - yBar; ssTot += d * d
    }
    if ssTot <= 1e-12 { return ssRes <= 1e-12 ? 1 : 0 }
    let r = 1 - ssRes / ssTot
    return r.isFinite ? r : 0   // a non-finite input (NaN/Inf) collapses to "worst fit", never propagates
}

// MARK: - Fits

/// Ordinary least-squares line y = m·x + b, with R² and parameter standard errors (error bars).
public func linearFit(_ points: [Point2D]) -> LinearFit? {
    let n = points.count
    guard n >= 2 else { return nil }
    let N = Double(n)
    let sx = points.reduce(0) { $0 + $1.x }
    let sy = points.reduce(0) { $0 + $1.y }
    let sxx = points.reduce(0) { $0 + $1.x * $1.x }
    let sxy = points.reduce(0) { $0 + $1.x * $1.y }
    let denom = N * sxx - sx * sx
    guard abs(denom) > 1e-12 else { return nil }   // degenerate: all x equal
    let m = (N * sxy - sx * sy) / denom
    let b = (sy - m * sx) / N
    let r2 = rSquared(points) { m * $0 + b }

    var seSlope = 0.0, seIntercept = 0.0
    if n >= 3 {
        let ssRes = points.reduce(0.0) { acc, p in let e = p.y - (m * p.x + b); return acc + e * e }
        let sxxCentered = sxx - sx * sx / N
        if sxxCentered > 1e-12 {
            let resVar = ssRes / (N - 2)
            seSlope = sqrt(resVar / sxxCentered)
            seIntercept = seSlope * sqrt(sxx / N)
        }
    }
    return LinearFit(slope: m, intercept: b, rSquared: r2, slopeStdError: seSlope, interceptStdError: seIntercept)
}

/// Polynomial least squares of the given degree (≥1), via the normal equations.
public func polynomialFit(_ points: [Point2D], degree: Int) -> PolyFit? {
    guard degree >= 1, points.count >= degree + 1 else { return nil }
    let m = degree + 1
    var A = Array(repeating: Array(repeating: 0.0, count: m), count: m)
    var v = Array(repeating: 0.0, count: m)
    for p in points {
        var xpow = [Double](repeating: 1, count: 2 * degree + 1)
        if 2 * degree >= 1 { for k in 1...(2 * degree) { xpow[k] = xpow[k - 1] * p.x } }
        for j in 0..<m {
            for k in 0..<m { A[j][k] += xpow[j + k] }
            v[j] += p.y * xpow[j]
        }
    }
    guard let c = solveLinearSystem(A, v) else { return nil }
    let r2 = rSquared(points) { x in var r = 0.0; for (i, ci) in c.enumerated() { r += ci * pow(x, Double(i)) }; return r }
    return PolyFit(coefficients: c, rSquared: r2)
}

/// Exponential fit y = a·e^(b·x) by linear regression on ln(y) (requires all y > 0).
public func exponentialFit(_ points: [Point2D]) -> ExpFit? {
    guard points.count >= 2, points.allSatisfy({ $0.y > 0 }) else { return nil }
    guard let lf = linearFit(points.map { Point2D(x: $0.x, y: log($0.y)) }) else { return nil }
    let b = lf.slope, a = exp(lf.intercept)
    return ExpFit(a: a, b: b, rSquared: rSquared(points) { a * exp(b * $0) })
}

/// Power-law fit y = a·x^b by linear regression on ln(y) vs ln(x) (requires all x,y > 0).
public func powerFit(_ points: [Point2D]) -> PowerFit? {
    guard points.count >= 2, points.allSatisfy({ $0.x > 0 && $0.y > 0 }) else { return nil }
    guard let lf = linearFit(points.map { Point2D(x: log($0.x), y: log($0.y)) }) else { return nil }
    let b = lf.slope, a = exp(lf.intercept)
    return PowerFit(a: a, b: b, rSquared: rSquared(points) { a * pow($0, b) })
}

// MARK: - Linear algebra (Gauss–Jordan with partial pivoting)

func solveLinearSystem(_ A0: [[Double]], _ b0: [Double]) -> [Double]? {
    var A = A0, b = b0
    let n = b.count
    for col in 0..<n {
        var pivot = col
        for r in (col + 1)..<n where abs(A[r][col]) > abs(A[pivot][col]) { pivot = r }
        guard abs(A[pivot][col]) > 1e-12 else { return nil }
        A.swapAt(col, pivot); b.swapAt(col, pivot)
        for r in 0..<n where r != col {
            let f = A[r][col] / A[col][col]
            if f != 0 {
                for k in col..<n { A[r][k] -= f * A[col][k] }
                b[r] -= f * b[col]
            }
        }
    }
    return (0..<n).map { b[$0] / A[$0][$0] }
}
