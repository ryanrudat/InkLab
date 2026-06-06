import Foundation

/// A physical dimension as a vector of the seven SI base-dimension exponents. Two quantities are
/// dimensionally compatible (addable, or the two sides of an equation) iff their `Dimension`s are
/// equal — that equality is what the checker verifies, exactly.
public struct Dimension: Equatable, Hashable, Sendable {
    public var L, M, T, I, Theta, N, J: Int   // length, mass, time, current, temperature, amount, luminous

    public init(L: Int = 0, M: Int = 0, T: Int = 0, I: Int = 0, Theta: Int = 0, N: Int = 0, J: Int = 0) {
        self.L = L; self.M = M; self.T = T; self.I = I; self.Theta = Theta; self.N = N; self.J = J
    }

    public static let dimensionless = Dimension()
    public var isDimensionless: Bool { self == .dimensionless }

    public static func * (a: Dimension, b: Dimension) -> Dimension {   // multiplying quantities adds exponents
        Dimension(L: a.L + b.L, M: a.M + b.M, T: a.T + b.T, I: a.I + b.I, Theta: a.Theta + b.Theta, N: a.N + b.N, J: a.J + b.J)
    }
    public static func / (a: Dimension, b: Dimension) -> Dimension {
        Dimension(L: a.L - b.L, M: a.M - b.M, T: a.T - b.T, I: a.I - b.I, Theta: a.Theta - b.Theta, N: a.N - b.N, J: a.J - b.J)
    }
    public func pow(_ n: Int) -> Dimension {
        Dimension(L: L*n, M: M*n, T: T*n, I: I*n, Theta: Theta*n, N: N*n, J: J*n)
    }
    /// The k-th root, if every exponent is divisible by k (e.g. √(area) = length); else nil.
    public func root(_ k: Int) -> Dimension? {
        let e = [L, M, T, I, Theta, N, J]
        guard k != 0, e.allSatisfy({ $0 % k == 0 }) else { return nil }
        return Dimension(L: L/k, M: M/k, T: T/k, I: I/k, Theta: Theta/k, N: N/k, J: J/k)
    }

    /// Readable SI form, e.g. force -> "kg·m·s^-2", dimensionless -> "dimensionless".
    public var symbol: String {
        let parts: [(String, Int)] = [("kg", M), ("m", L), ("s", T), ("A", I), ("K", Theta), ("mol", N), ("cd", J)]
        let nz = parts.filter { $0.1 != 0 }
        if nz.isEmpty { return "dimensionless" }
        return nz.map { $0.1 == 1 ? $0.0 : "\($0.0)^\($0.1)" }.joined(separator: "·")
    }

    // Named dimensions (computed lazily, so cross-references resolve regardless of order).
    public static let length = Dimension(L: 1)
    public static let mass = Dimension(M: 1)
    public static let time = Dimension(T: 1)
    public static let current = Dimension(I: 1)
    public static let temperature = Dimension(Theta: 1)
    public static let amount = Dimension(N: 1)
    public static let luminous = Dimension(J: 1)
    public static let area = length.pow(2)
    public static let volume = length.pow(3)
    public static let velocity = length / time
    public static let acceleration = velocity / time
    public static let force = mass * acceleration
    public static let energy = force * length
    public static let power = energy / time
    public static let charge = current * time
    public static let voltage = power / current
    public static let pressure = force / area
    public static let frequency = Dimension(T: -1)
}
