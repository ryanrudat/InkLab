import Foundation

/// A single variable/atom raised to a positive power. An "atom" is either a real variable (x, y) or
/// an opaque sub-expression we don't expand (e.g. sin(x), √2) — treated as an indeterminate so that
/// algebra AROUND it is still checked exactly (sin(x)+sin(x) == 2·sin(x) is verified; identities like
/// sin²+cos²=1 are conservatively NOT assumed).
public struct Power: Hashable, Comparable, Sendable {
    public let atom: String
    public let exp: Int
    public static func < (a: Power, b: Power) -> Bool { a.atom == b.atom ? a.exp < b.exp : a.atom < b.atom }
}

/// A product of distinct atoms with exponents (e.g. x^2·y). Stored sorted+normalized so equal
/// monomials hash equal.
public struct Monomial: Hashable, Comparable, Sendable {
    public let powers: [Power]   // sorted by atom; no zero exponents; no duplicate atoms

    public init(_ map: [String: Int]) {
        powers = map.filter { $0.value != 0 }
                    .map { Power(atom: $0.key, exp: $0.value) }
                    .sorted { $0.atom < $1.atom }
    }
    private init(sorted: [Power]) { powers = sorted }

    public static let one = Monomial([:])    // the empty product == 1
    public var isOne: Bool { powers.isEmpty }
    public var totalDegree: Int { powers.reduce(0) { $0 + $1.exp } }

    public static func * (a: Monomial, b: Monomial) -> Monomial {
        var m: [String: Int] = [:]
        for p in a.powers { m[p.atom, default: 0] += p.exp }
        for p in b.powers { m[p.atom, default: 0] += p.exp }
        return Monomial(m)
    }

    // Canonical ordering: by total degree, then lexicographically by atom powers.
    public static func < (a: Monomial, b: Monomial) -> Bool {
        if a.totalDegree != b.totalDegree { return a.totalDegree < b.totalDegree }
        return a.powers.lexicographicallyPrecedes(b.powers)
    }

    public func evaluated(_ env: [String: Rational]) -> Rational {
        var r = Rational.one
        for p in powers { r = r * (env[p.atom] ?? .zero).power(p.exp) }
        return r
    }
    public var atoms: Set<String> { Set(powers.map(\.atom)) }
}

/// A multivariate polynomial with rational coefficients: a map monomial -> coefficient, kept pruned
/// of zero coefficients so two polynomials are equal iff their maps are equal.
public struct Polynomial: Equatable, Sendable {
    public private(set) var terms: [Monomial: Rational]

    public init(_ terms: [Monomial: Rational] = [:]) {
        self.terms = terms.filter { !$0.value.isZero }
    }
    public static let zero = Polynomial()
    public static func constant(_ c: Rational) -> Polynomial { c.isZero ? .zero : Polynomial([.one: c]) }
    public static func atom(_ name: String) -> Polynomial { Polynomial([Monomial([name: 1]): .one]) }

    public var isZero: Bool { terms.isEmpty }
    public var atoms: Set<String> { terms.keys.reduce(into: Set()) { $0.formUnion($1.atoms) } }

    /// The constant value if this polynomial is a constant (0 or just a number), else nil.
    public var constantValue: Rational? {
        if isZero { return .zero }
        if terms.count == 1, let c = terms[.one] { return c }
        return nil
    }

    public static func + (a: Polynomial, b: Polynomial) -> Polynomial {
        var t = a.terms
        for (m, c) in b.terms { t[m, default: .zero] = t[m, default: .zero] + c }
        return Polynomial(t)
    }
    public static prefix func - (a: Polynomial) -> Polynomial { Polynomial(a.terms.mapValues { -$0 }) }
    public static func - (a: Polynomial, b: Polynomial) -> Polynomial { a + (-b) }
    public static func * (a: Polynomial, b: Polynomial) -> Polynomial {
        var t: [Monomial: Rational] = [:]
        for (ma, ca) in a.terms { for (mb, cb) in b.terms {
            let m = ma * mb
            t[m, default: .zero] = t[m, default: .zero] + ca * cb
        } }
        return Polynomial(t)
    }
    public func scaled(_ c: Rational) -> Polynomial { Polynomial(terms.mapValues { $0 * c }) }
    public func power(_ e: Int) -> Polynomial {
        precondition(e >= 0)
        var r = Polynomial.constant(.one)
        for _ in 0..<e { r = r * self }
        return r
    }
    public func evaluated(_ env: [String: Rational]) -> Rational {
        terms.reduce(Rational.zero) { $0 + $1.value * $1.key.evaluated(env) }
    }

    /// If `self` and `other` are non-zero rational-scalar multiples of one another, returns the
    /// constant k with self == k·other; otherwise nil. (Used to validate equation steps: the legal
    /// moves — add/subtract the same thing to both sides, scale both sides by a nonzero constant —
    /// all leave the "L − R" difference scaled by a constant, preserving the solution set.)
    public func proportionalConstant(to other: Polynomial) -> Rational? {
        if isZero && other.isZero { return .one }
        if isZero || other.isZero { return nil }
        guard terms.count == other.terms.count else { return nil }
        var k: Rational? = nil
        for (m, c) in terms {
            guard let c2 = other.terms[m] else { return nil }       // different monomial support
            let ratio = c / c2
            if let k = k { if ratio != k { return nil } } else { k = ratio }
        }
        return k
    }
}
