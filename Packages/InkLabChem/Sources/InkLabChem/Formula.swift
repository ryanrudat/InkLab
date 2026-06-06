import Foundation

/// Parse a molecular formula into element counts. Handles element symbols (Na, Cl, …), counts,
/// and nested parentheses with multipliers: "Ca(OH)2" -> [Ca:1, O:2, H:2], "C6H12O6", "Fe2O3".
/// Returns nil on an unknown element or malformed input.
public func parseFormula(_ s: String) -> [String: Int]? {
    let cs = Array(s)
    var i = 0

    func number() -> Int? {
        var str = ""
        while i < cs.count, cs[i].isNumber { str.append(cs[i]); i += 1 }
        return str.isEmpty ? nil : Int(str)
    }

    // Parse a sequence of element/group tokens until `stop` (or end). Recursive for parentheses.
    func sequence(until stop: Character?) -> [String: Int]? {
        var counts: [String: Int] = [:]
        while i < cs.count {
            let c = cs[i]
            if let stop, c == stop { break }
            if c == " " { i += 1; continue }
            if c == "(" {
                i += 1
                guard let inner = sequence(until: ")"), i < cs.count, cs[i] == ")" else { return nil }
                i += 1
                let mult = number() ?? 1
                for (k, v) in inner { counts[k, default: 0] += v * mult }
            } else if c.isUppercase {
                var sym = String(c); i += 1
                while i < cs.count, cs[i].isLowercase { sym.append(cs[i]); i += 1 }
                guard Elements.isElement(sym) else { return nil }
                counts[sym, default: 0] += number() ?? 1
            } else {
                return nil   // unexpected character (digit at start, stray symbol, …)
            }
        }
        return counts
    }

    guard let result = sequence(until: nil), i == cs.count else { return nil }
    return result.isEmpty ? nil : result
}

/// Molar mass in g/mol, or nil if the formula can't be parsed / has an unknown element.
public func molarMass(_ formula: String) -> Double? {
    guard let counts = parseFormula(formula) else { return nil }
    var total = 0.0
    for (sym, n) in counts {
        guard let w = Elements.weight(sym) else { return nil }
        total += w * Double(n)
    }
    return total
}
