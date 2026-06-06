import Foundation

/// Exact rational used for the balancing linear algebra, so coefficients are found exactly (no
/// floating-point drift) and reduce cleanly to smallest integers.
struct Frac: Equatable {
    let n: Int, d: Int
    init(_ n: Int, _ d: Int = 1) {
        precondition(d != 0)
        var n = n, d = d
        if d < 0 { n = -n; d = -d }
        let g = Frac.gcd(abs(n), d)
        self.n = g == 0 ? 0 : n / g
        self.d = g == 0 ? 1 : d / g
    }
    static func gcd(_ a: Int, _ b: Int) -> Int { var a = a, b = b; while b != 0 { (a, b) = (b, a % b) }; return a }
    static let zero = Frac(0)
    var isZero: Bool { n == 0 }
    static func + (a: Frac, b: Frac) -> Frac { Frac(a.n * b.d + b.n * a.d, a.d * b.d) }
    static func - (a: Frac, b: Frac) -> Frac { Frac(a.n * b.d - b.n * a.d, a.d * b.d) }
    static func * (a: Frac, b: Frac) -> Frac { Frac(a.n * b.n, a.d * b.d) }
    static func / (a: Frac, b: Frac) -> Frac { Frac(a.n * b.d, a.d * b.n) }
    static prefix func - (a: Frac) -> Frac { Frac(-a.n, a.d) }
}

func lcm(_ a: Int, _ b: Int) -> Int { a == 0 || b == 0 ? 0 : abs(a / Frac.gcd(abs(a), abs(b)) * b) }
