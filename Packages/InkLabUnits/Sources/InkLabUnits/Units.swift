import Foundation

/// The unit registry: maps a unit symbol to its dimension and its scale to SI base units (kg, m, s,
/// A, K, mol, cd). Handles SI prefixes (km, ms, µg…) by splitting prefix + base unit.
public enum Units {
    static let table: [String: (Dimension, Double)] = [
        // SI base (scale relative to the SI base unit; SI base for mass is the kilogram)
        "m": (.length, 1), "s": (.time, 1), "kg": (.mass, 1), "g": (.mass, 1e-3),
        "A": (.current, 1), "K": (.temperature, 1), "mol": (.amount, 1), "cd": (.luminous, 1),
        // common derived
        "N": (.force, 1), "J": (.energy, 1), "W": (.power, 1), "Pa": (.pressure, 1),
        "C": (.charge, 1), "V": (.voltage, 1), "Hz": (.frequency, 1), "rad": (.dimensionless, 1),
        "min": (.time, 60), "h": (.time, 3600), "L": (.volume, 1e-3),
    ]
    static let prefixes: [String: Double] = [
        "da": 1e1, "k": 1e3, "M": 1e6, "G": 1e9, "T": 1e12,
        "d": 1e-1, "c": 1e-2, "m": 1e-3, "u": 1e-6, "n": 1e-9, "p": 1e-12, "h": 1e2,
    ]

    /// Resolve a single unit symbol (with optional SI prefix) to (dimension, scale-to-SI).
    public static func symbol(_ s: String) -> (Dimension, Double)? {
        if let u = table[s] { return u }                       // whole symbol wins (min, mol, kg, …)
        for plen in [2, 1] where s.count > plen {
            let pfx = String(s.prefix(plen)), rest = String(s.dropFirst(plen))
            if let p = prefixes[pfx], let u = table[rest] { return (u.0, p * u.1) }
        }
        return nil
    }
}
