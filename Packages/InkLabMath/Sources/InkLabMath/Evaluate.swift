import Foundation

/// Numerically evaluate an `Expr` given variable values. Returns nil when a variable is missing or
/// the expression isn't defined there (division by zero, ln of a non-positive, …).
public func numericValue(_ e: Expr, _ env: [String: Double]) -> Double? {
    func nv(_ x: Expr) -> Double? { numericValue(x, env) }
    switch e {
    case .num(let r): return Double(r.num) / Double(r.den)
    case .variable(let v): return env[v]
    case .neg(let a): return nv(a).map { -$0 }
    case .add(let a, let b): if let x = nv(a), let y = nv(b) { return x + y }; return nil
    case .sub(let a, let b): if let x = nv(a), let y = nv(b) { return x - y }; return nil
    case .mul(let a, let b): if let x = nv(a), let y = nv(b) { return x * y }; return nil
    case .div(let a, let b): if let x = nv(a), let y = nv(b), y != 0 { return x / y }; return nil
    case .pow(let a, let b): if let x = nv(a), let y = nv(b) { return Foundation.pow(x, y) }; return nil
    case .funcApp(let name, let args):
        guard args.count == 1, let x = nv(args[0]) else { return nil }
        switch name {
        case "sin": return sin(x)
        case "cos": return cos(x)
        case "tan": return tan(x)
        case "exp": return exp(x)
        case "sqrt": return x >= 0 ? sqrt(x) : nil
        case "ln": return x > 0 ? log(x) : nil
        case "log": return x > 0 ? log10(x) : nil
        case "abs": return Swift.abs(x)
        default: return nil
        }
    case .deriv: return nil   // symbolic derivative isn't a numeric leaf here
    }
}

/// The variable names an expression references.
public func variables(in e: Expr) -> Set<String> {
    switch e {
    case .num: return []
    case .variable(let v): return [v]
    case .neg(let a): return variables(in: a)
    case .add(let a, let b), .sub(let a, let b), .mul(let a, let b), .div(let a, let b), .pow(let a, let b):
        return variables(in: a).union(variables(in: b))
    case .funcApp(_, let args): return args.reduce(into: Set()) { $0.formUnion(variables(in: $1)) }
    case .deriv(let inner, _): return variables(in: inner)
    }
}
