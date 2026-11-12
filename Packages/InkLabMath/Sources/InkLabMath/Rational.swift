import Foundation

/// Exact rational number (kept reduced, denominator > 0). Exactness is what makes the tutor's
/// verdicts correct by construction — no floating-point "1/3 ≈ 0.333" ambiguity.
///
/// Arithmetic is OVERFLOW-SAFE: every operation uses checked Int math and, on Int64 overflow (or a
/// zero/`Int.min` divisor), yields an absorbing `overflow` sentinel (`den == 0`) instead of trapping.
/// This preserves the engine's "correct-or-silent, never crash" contract — the tutor/canonicalizer
/// detect `isOverflow` at their comparison boundaries and degrade to `.unsupported` rather than
/// crashing the app or, worse, emitting a wrong verdict. (A previous version used trapping `*`/`+`,
/// so ordinary inputs like `2^100` or a long decimal killed the whole process.)
public struct Rational: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let num: Int
    public let den: Int

    /// Absorbing "overflow / undefined" value (`den == 0`). Any arithmetic touching it stays overflow.
    public static let overflow = Rational(unchecked: 1, den: 0)
    public var isOverflow: Bool { den == 0 }

    private init(unchecked num: Int, den: Int) { self.num = num; self.den = den }

    public init(_ n: Int, _ d: Int = 1) {
        // A zero denominator, or an Int.min operand (whose magnitude can't be negated without overflow),
        // becomes the overflow sentinel rather than trapping.
        if d == 0 || n == Int.min || d == Int.min { self.num = 1; self.den = 0; return }
        var n = n, d = d
        if d < 0 { n = -n; d = -d }
        let g = Rational.gcd(Swift.abs(n), d)   // n != Int.min here, so abs is safe
        self.num = g == 0 ? 0 : n / g
        self.den = g == 0 ? 1 : d / g
    }

    static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    // Checked Int helpers — return nil on overflow instead of trapping.
    private static func cmul(_ a: Int, _ b: Int) -> Int? { let (r, o) = a.multipliedReportingOverflow(by: b); return o ? nil : r }
    private static func cadd(_ a: Int, _ b: Int) -> Int? { let (r, o) = a.addingReportingOverflow(b); return o ? nil : r }
    private static func csub(_ a: Int, _ b: Int) -> Int? { let (r, o) = a.subtractingReportingOverflow(b); return o ? nil : r }

    public static let zero = Rational(0)
    public static let one = Rational(1)
    public var isZero: Bool { num == 0 && den != 0 }
    public var isInteger: Bool { den == 1 }

    public static func + (a: Rational, b: Rational) -> Rational {
        if a.isOverflow || b.isOverflow { return .overflow }
        guard let ad = cmul(a.num, b.den), let bd = cmul(b.num, a.den), let n = cadd(ad, bd), let d = cmul(a.den, b.den) else { return .overflow }
        return Rational(n, d)
    }
    public static func - (a: Rational, b: Rational) -> Rational {
        if a.isOverflow || b.isOverflow { return .overflow }
        guard let ad = cmul(a.num, b.den), let bd = cmul(b.num, a.den), let n = csub(ad, bd), let d = cmul(a.den, b.den) else { return .overflow }
        return Rational(n, d)
    }
    public static func * (a: Rational, b: Rational) -> Rational {
        if a.isOverflow || b.isOverflow { return .overflow }
        guard let n = cmul(a.num, b.num), let d = cmul(a.den, b.den) else { return .overflow }
        return Rational(n, d)
    }
    public static func / (a: Rational, b: Rational) -> Rational {
        if a.isOverflow || b.isOverflow { return .overflow }
        guard let n = cmul(a.num, b.den), let d = cmul(a.den, b.num) else { return .overflow }
        return Rational(n, d)   // b == 0 ⇒ d == 0 ⇒ overflow sentinel (no trap)
    }
    public static prefix func - (a: Rational) -> Rational {
        if a.isOverflow || a.num == Int.min { return .overflow }
        return Rational(-a.num, a.den)
    }

    public static func < (a: Rational, b: Rational) -> Bool {
        if a.isOverflow || b.isOverflow { return false }
        let (l, lo) = a.num.multipliedReportingOverflow(by: b.den)
        let (r, ro) = b.num.multipliedReportingOverflow(by: a.den)
        if lo || ro { return (Double(a.num) / Double(a.den)) < (Double(b.num) / Double(b.den)) }
        return l < r
    }

    public func power(_ e: Int) -> Rational {
        if isOverflow { return .overflow }
        if e == 0 { return .one }
        if e == Int.min { return .overflow }
        if e > 0 {
            guard let n = Rational.intPow(num, e), let d = Rational.intPow(den, e) else { return .overflow }
            return Rational(n, d)
        }
        guard let n = Rational.intPow(den, -e), let d = Rational.intPow(num, -e) else { return .overflow }
        return Rational(n, d)   // num == 0 ⇒ d == 0 ⇒ overflow
    }
    private static func intPow(_ base: Int, _ exp: Int) -> Int? {
        var result = 1
        var factor = base
        var exponent = exp
        while exponent > 0 {
            if exponent & 1 == 1 {
                guard let multiplied = cmul(result, factor) else { return nil }
                result = multiplied
            }
            exponent >>= 1
            if exponent > 0 {
                guard let squared = cmul(factor, factor) else { return nil }
                factor = squared
            }
        }
        return result
    }

    public var description: String { isOverflow ? "overflow" : (den == 1 ? "\(num)" : "\(num)/\(den)") }
}
