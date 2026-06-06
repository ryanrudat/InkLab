import Foundation

/// Exact rational number (kept reduced, denominator > 0). Exactness is what makes the tutor's
/// verdicts correct by construction — no floating-point "1/3 ≈ 0.333" ambiguity.
public struct Rational: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let num: Int
    public let den: Int

    public init(_ n: Int, _ d: Int = 1) {
        precondition(d != 0, "rational with zero denominator")
        var n = n, d = d
        if d < 0 { n = -n; d = -d }
        let g = Rational.gcd(abs(n), d)
        self.num = g == 0 ? 0 : n / g
        self.den = g == 0 ? 1 : d / g
    }

    static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    public static let zero = Rational(0)
    public static let one = Rational(1)
    public var isZero: Bool { num == 0 }
    public var isInteger: Bool { den == 1 }

    public static func + (a: Rational, b: Rational) -> Rational { Rational(a.num * b.den + b.num * a.den, a.den * b.den) }
    public static func - (a: Rational, b: Rational) -> Rational { Rational(a.num * b.den - b.num * a.den, a.den * b.den) }
    public static func * (a: Rational, b: Rational) -> Rational { Rational(a.num * b.num, a.den * b.den) }
    public static func / (a: Rational, b: Rational) -> Rational { Rational(a.num * b.den, a.den * b.num) }
    public static prefix func - (a: Rational) -> Rational { Rational(-a.num, a.den) }

    public static func < (a: Rational, b: Rational) -> Bool { a.num * b.den < b.num * a.den }

    public func power(_ e: Int) -> Rational {
        if e == 0 { return .one }
        if e > 0 { return Rational(intPow(num, e), intPow(den, e)) }
        return Rational(intPow(den, -e), intPow(num, -e))
    }
    private func intPow(_ base: Int, _ exp: Int) -> Int {
        var r = 1; for _ in 0..<exp { r *= base }; return r
    }

    public var description: String { den == 1 ? "\(num)" : "\(num)/\(den)" }
}
