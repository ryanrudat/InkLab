import Foundation

public enum UnitError: Error, Equatable, Sendable {
    case unknownSymbol(String)
    case cannotAdd(Dimension, Dimension)
    case nonDimensionlessArgument(function: String, got: Dimension)
    case cannotRoot(Dimension)
}

public enum UnitVerdict: Equatable, Sendable {
    case consistent(Dimension)     // dimensionally sound; carries the resulting dimension
    case mismatch(String)          // a dimensional error, explained
    case unsupported(String)       // unparseable / unknown symbol
}

/// Resolve a symbol to a dimension: declared variables (`env`) take precedence over the unit
/// registry, so you can use `t` for a time variable even though `t` isn't a registered unit.
func dimension(of e: UExpr, env: [String: Dimension]) -> Result<Dimension, UnitError> {
    func look(_ s: String) -> Dimension? { env[s] ?? Units.symbol(s)?.0 }
    func go(_ e: UExpr) -> Result<Dimension, UnitError> {
        switch e {
        case .num: return .success(.dimensionless)
        case .sym(let s): return look(s).map { .success($0) } ?? .failure(.unknownSymbol(s))
        case .neg(let a): return go(a)
        case .add(let a, let b), .sub(let a, let b):
            return go(a).flatMap { da in go(b).flatMap { db in da == db ? .success(da) : .failure(.cannotAdd(da, db)) } }
        case .mul(let a, let b): return go(a).flatMap { da in go(b).map { da * $0 } }
        case .div(let a, let b): return go(a).flatMap { da in go(b).map { da / $0 } }
        case .pow(let a, let n): return go(a).map { $0.pow(n) }
        case .funcApp(let name, let arg):
            return go(arg).flatMap { da in
                if name == "sqrt" { return da.root(2).map { .success($0) } ?? .failure(.cannotRoot(da)) }
                return da.isDimensionless ? .success(.dimensionless) : .failure(.nonDimensionlessArgument(function: name, got: da))
            }
        }
    }
    return go(e)
}

private func verdict(for error: UnitError) -> UnitVerdict {
    switch error {
    case .unknownSymbol(let s): return .unsupported("unknown unit or undeclared variable '\(s)'")
    case .cannotAdd(let a, let b): return .mismatch("can't add or compare \(a.symbol) and \(b.symbol)")
    case .nonDimensionlessArgument(let fn, let d): return .mismatch("\(fn)(…) needs a dimensionless argument, but got \(d.symbol)")
    case .cannotRoot(let d): return .mismatch("can't take the square root of \(d.symbol)")
    }
}

// MARK: - Public API

/// Dimension of a single unit expression (e.g. "kg m / s^2"), ignoring any variables. Use it to
/// declare a variable's dimension: `["a": dimensionOf("m/s^2")!]`.
public func dimensionOf(_ unitExpr: String) -> Dimension? {
    guard let e = try? parseUExpr(unitExpr) else { return nil }
    return try? dimension(of: e, env: [:]).get()
}

/// Are two unit expressions the same dimension? ("N" vs "kg m/s^2" → true.)
public func unitsEqual(_ a: String, _ b: String) -> Bool {
    guard let da = dimensionOf(a), let db = dimensionOf(b) else { return false }
    return da == db
}

/// Check the dimensional consistency of an expression, given the dimensions of any variables used.
public func checkExpression(_ s: String, env: [String: Dimension] = [:]) -> UnitVerdict {
    guard let e = try? parseUExpr(s) else { return .unsupported("couldn't parse \"\(s)\"") }
    switch dimension(of: e, env: env) {
    case .success(let d): return .consistent(d)
    case .failure(let err): return verdict(for: err)
    }
}

/// Check that the two sides of an equation "L = R" have the same dimension.
public func checkEquation(_ s: String, env: [String: Dimension] = [:]) -> UnitVerdict {
    guard let eq = s.firstIndex(of: "=") else { return checkExpression(s, env: env) }
    let lhs = String(s[s.startIndex..<eq]), rhs = String(s[s.index(after: eq)...])
    guard let le = try? parseUExpr(lhs), let re = try? parseUExpr(rhs) else { return .unsupported("couldn't parse equation") }
    let l = dimension(of: le, env: env), r = dimension(of: re, env: env)
    if case .failure(let e) = l { return verdict(for: e) }
    if case .failure(let e) = r { return verdict(for: e) }
    guard case .success(let ld) = l, case .success(let rd) = r else { return .unsupported("internal") }
    return ld == rd ? .consistent(ld) : .mismatch("left side is \(ld.symbol) but right side is \(rd.symbol)")
}
