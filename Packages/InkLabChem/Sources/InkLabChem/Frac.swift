import Foundation

/// Exact rational used for the balancing linear algebra, so coefficients are found exactly (no
/// floating-point drift) and reduce cleanly to smallest integers.
///
/// OVERFLOW-SAFE: every operation uses checked Int math and, on Int64 overflow (or a zero/`Int.min`
/// divisor), yields an absorbing `overflow` sentinel (`d == 0`) instead of trapping. The RREF in
/// `nullSpace` can blow numerators/denominators up for a large multi-species equation; previously
/// that crashed the whole app — now `balance` detects `isOverflow` and returns `.cannotBalance`.
struct Frac: Equatable {
    let n: Int, d: Int

    static let overflow = Frac(unchecked: 1, d: 0)
    var isOverflow: Bool { d == 0 }
    private init(unchecked n: Int, d: Int) { self.n = n; self.d = d }

    init(_ n: Int, _ d: Int = 1) {
        if d == 0 || n == Int.min || d == Int.min { self.n = 1; self.d = 0; return }  // overflow sentinel
        var n = n, d = d
        if d < 0 { n = -n; d = -d }
        let g = Frac.gcd(abs(n), d)   // n != Int.min here
        self.n = g == 0 ? 0 : n / g
        self.d = g == 0 ? 1 : d / g
    }
    static func gcd(_ a: Int, _ b: Int) -> Int { var a = a, b = b; while b != 0 { (a, b) = (b, a % b) }; return a }

    private static func cmul(_ a: Int, _ b: Int) -> Int? { let (r, o) = a.multipliedReportingOverflow(by: b); return o ? nil : r }
    private static func cadd(_ a: Int, _ b: Int) -> Int? { let (r, o) = a.addingReportingOverflow(b); return o ? nil : r }
    private static func csub(_ a: Int, _ b: Int) -> Int? { let (r, o) = a.subtractingReportingOverflow(b); return o ? nil : r }

    static let zero = Frac(0)
    var isZero: Bool { n == 0 && d != 0 }

    static func + (a: Frac, b: Frac) -> Frac {
        if a.isOverflow || b.isOverflow { return .overflow }
        guard let ad = cmul(a.n, b.d), let bd = cmul(b.n, a.d), let n = cadd(ad, bd), let d = cmul(a.d, b.d) else { return .overflow }
        return Frac(n, d)
    }
    static func - (a: Frac, b: Frac) -> Frac {
        if a.isOverflow || b.isOverflow { return .overflow }
        guard let ad = cmul(a.n, b.d), let bd = cmul(b.n, a.d), let n = csub(ad, bd), let d = cmul(a.d, b.d) else { return .overflow }
        return Frac(n, d)
    }
    static func * (a: Frac, b: Frac) -> Frac {
        if a.isOverflow || b.isOverflow { return .overflow }
        guard let n = cmul(a.n, b.n), let d = cmul(a.d, b.d) else { return .overflow }
        return Frac(n, d)
    }
    static func / (a: Frac, b: Frac) -> Frac {
        if a.isOverflow || b.isOverflow { return .overflow }
        guard let n = cmul(a.n, b.d), let d = cmul(a.d, b.n) else { return .overflow }
        return Frac(n, d)   // b == 0 ⇒ d == 0 ⇒ overflow sentinel
    }
    static prefix func - (a: Frac) -> Frac {
        if a.isOverflow || a.n == Int.min { return .overflow }
        return Frac(-a.n, a.d)
    }
}

/// Least common multiple, checked. Returns nil on overflow; 0 if either input is 0. Inputs are
/// denominators (always positive), so `abs` is safe.
func lcm(_ a: Int, _ b: Int) -> Int? {
    if a == 0 || b == 0 { return 0 }
    let g = Frac.gcd(abs(a), abs(b))
    let (m, o) = (a / g).multipliedReportingOverflow(by: b)
    return o ? nil : abs(m)
}
