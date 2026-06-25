import Foundation

/// An expression in exact canonical form: a ratio of two multivariate polynomials over ℚ. Two
/// expressions are mathematically equal iff num₁·den₂ − num₂·den₁ ≡ 0 (cross-multiply) — an EXACT,
/// deterministic test, not a numeric approximation.
public struct RationalFunction: Sendable {
    public var num: Polynomial
    public var den: Polynomial
    public init(num: Polynomial, den: Polynomial = .constant(.one)) { self.num = num; self.den = den }

    public var isWellDefined: Bool { !den.isZero }
    /// True if exact arithmetic overflowed Int64 anywhere in the numerator or denominator.
    public var isOverflow: Bool { num.isOverflow || den.isOverflow }

    public static func + (a: RationalFunction, b: RationalFunction) -> RationalFunction {
        RationalFunction(num: a.num * b.den + b.num * a.den, den: a.den * b.den)
    }
    public static func - (a: RationalFunction, b: RationalFunction) -> RationalFunction {
        RationalFunction(num: a.num * b.den - b.num * a.den, den: a.den * b.den)
    }
    public static func * (a: RationalFunction, b: RationalFunction) -> RationalFunction {
        RationalFunction(num: a.num * b.num, den: a.den * b.den)
    }
    public static func / (a: RationalFunction, b: RationalFunction) -> RationalFunction {
        RationalFunction(num: a.num * b.den, den: a.den * b.num)
    }
    public func scaled(_ c: Rational) -> RationalFunction { RationalFunction(num: num.scaled(c), den: den) }
    public func power(_ e: Int) -> RationalFunction {
        if e >= 0 { return RationalFunction(num: num.power(e), den: den.power(e)) }
        return RationalFunction(num: den.power(-e), den: num.power(-e))
    }

    /// Exact mathematical equality of two expressions (assuming denominators are non-zero).
    public func equals(_ other: RationalFunction) -> Bool {
        (num * other.den - other.num * den).isZero
    }
    /// The single difference polynomial whose roots are the solutions of "this == other".
    public func differenceNumerator(_ other: RationalFunction) -> Polynomial {
        num * other.den - other.num * den
    }
}

// MARK: - Expr -> canonical form (total; unknown/transcendental parts become opaque atoms)

public func canonicalize(_ e: Expr) -> RationalFunction {
    switch e {
    case .num(let r): return RationalFunction(num: .constant(r))
    case .variable(let v): return RationalFunction(num: .atom(v))
    case .neg(let a): return canonicalize(a).scaled(Rational(-1))
    case .add(let a, let b): return canonicalize(a) + canonicalize(b)
    case .sub(let a, let b): return canonicalize(a) - canonicalize(b)
    case .mul(let a, let b): return canonicalize(a) * canonicalize(b)
    case .div(let a, let b): return canonicalize(a) / canonicalize(b)
    case .pow(let base, let exp):
        if let n = integerValue(of: exp) {
            // Cap the expansion: an enormous exponent would hang the repeated-multiply expansion and/or
            // overflow exact arithmetic. Beyond the cap, treat the power as an opaque atom so the tutor
            // stays correct-or-silent (it won't verify identities it can't expand, but it won't hang/crash).
            if n < -4096 || n > 4096 {
                return RationalFunction(num: .atom("(\(canonicalKey(base)))^(\(n))"))
            }
            return canonicalize(base).power(n)
        }
        // Symbolic/fractional exponent: treat the whole power as an opaque atom (e.g. 2^x, x^(1/2)).
        return RationalFunction(num: .atom("(\(canonicalKey(base)))^(\(canonicalKey(exp)))"))
    case .funcApp(let name, let args):
        return RationalFunction(num: .atom("\(name)(\(args.map(canonicalKey).joined(separator: ",")))"))
    case .deriv(let inner, let v):
        return canonicalize(differentiate(inner, v))
    }
}

func integerValue(of e: Expr) -> Int? {
    let rf = canonicalize(e)
    guard let n = rf.num.constantValue, let d = rf.den.constantValue, !d.isZero else { return nil }
    let q = n / d
    return q.isInteger ? q.num : nil
}

// MARK: - Canonical string keys (so equal opaque subtrees map to the same atom)

func canonicalKey(_ e: Expr) -> String {
    let rf = canonicalize(e)
    return "(\(polyKey(rf.num)))/(\(polyKey(rf.den)))"
}
private func polyKey(_ p: Polynomial) -> String {
    p.terms.keys.sorted().map { m in "\(p.terms[m]!)·\(monoKey(m))" }.joined(separator: "+")
}
private func monoKey(_ m: Monomial) -> String {
    m.isOne ? "1" : m.powers.map { "\($0.atom)^\($0.exp)" }.joined(separator: "*")
}
