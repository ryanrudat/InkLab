import Foundation

/// A physics expression: numbers, unit/variable symbols (kept as whole symbols, NOT split into
/// single letters — "kg" is one unit), +, −, ×, ÷, integer powers, parentheses, implicit
/// multiplication ("5 m", "a t^2"), and function calls.
public indirect enum UExpr: Equatable, Sendable {
    case num(Double)
    case sym(String)
    case neg(UExpr)
    case add(UExpr, UExpr)
    case sub(UExpr, UExpr)
    case mul(UExpr, UExpr)
    case div(UExpr, UExpr)
    case pow(UExpr, Int)
    case funcApp(String, UExpr)
}

public enum UParseError: Error, Equatable, Sendable { case empty, badToken(String), badExponent, unexpectedEnd }

let uFunctions: Set<String> = ["sin", "cos", "tan", "exp", "ln", "log", "sqrt"]

enum UTok: Equatable { case num(Double), ident(String), plus, minus, star, slash, caret, lparen, rparen }

func uTokenize(_ s: String) throws -> [UTok] {
    var toks: [UTok] = []
    let cs = Array(s); var i = 0
    while i < cs.count {
        let c = cs[i]
        if c == " " || c == "\t" { i += 1; continue }
        if c.isNumber || (c == "." && i + 1 < cs.count && cs[i + 1].isNumber) {
            var str = ""
            while i < cs.count, cs[i].isNumber || cs[i] == "." { str.append(cs[i]); i += 1 }
            guard let v = Double(str) else { throw UParseError.badToken(str) }
            toks.append(.num(v)); continue
        }
        if c.isLetter {
            var name = ""
            while i < cs.count, cs[i].isLetter { name.append(cs[i]); i += 1 }
            toks.append(.ident(name)); continue
        }
        switch c {
        case "+": toks.append(.plus)
        case "-", "\u{2212}": toks.append(.minus)
        case "*", "\u{00D7}", "\u{22C5}": toks.append(.star)
        case "/", "\u{00F7}": toks.append(.slash)
        case "^": toks.append(.caret)
        case "(": toks.append(.lparen)
        case ")": toks.append(.rparen)
        default: throw UParseError.badToken(String(c))
        }
        i += 1
    }
    return toks
}

public func parseUExpr(_ s: String) throws -> UExpr {
    let t = s.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { throw UParseError.empty }
    var p = UParser(toks: try uTokenize(t))
    let e = try p.addSub()
    guard p.done else { throw UParseError.badToken("trailing input") }
    return e
}

struct UParser {
    let toks: [UTok]; var pos = 0
    init(toks: [UTok]) { self.toks = toks }
    var done: Bool { pos >= toks.count }
    func peek() -> UTok? { pos < toks.count ? toks[pos] : nil }
    mutating func eat() -> UTok { defer { pos += 1 }; return toks[pos] }

    mutating func addSub() throws -> UExpr {
        var lhs = try mulDiv()
        while let t = peek(), t == .plus || t == .minus { pos += 1; let r = try mulDiv(); lhs = (t == .plus) ? .add(lhs, r) : .sub(lhs, r) }
        return lhs
    }
    mutating func mulDiv() throws -> UExpr {
        var lhs = try unary()
        loop: while let t = peek() {
            switch t {
            case .star: pos += 1; lhs = .mul(lhs, try unary())
            case .slash: pos += 1; lhs = .div(lhs, try unary())
            case .num, .ident, .lparen: lhs = .mul(lhs, try unary())   // implicit multiplication
            default: break loop
            }
        }
        return lhs
    }
    mutating func unary() throws -> UExpr {
        if peek() == .minus { pos += 1; return .neg(try unary()) }
        if peek() == .plus { pos += 1; return try unary() }
        return try powTerm()
    }
    mutating func powTerm() throws -> UExpr {
        let base = try atom()
        if peek() == .caret {
            pos += 1
            var sign = 1
            if peek() == .minus { pos += 1; sign = -1 }
            guard case .num(let v) = peek(), v.rounded() == v else { throw UParseError.badExponent }
            pos += 1
            return .pow(base, sign * Int(v))
        }
        return base
    }
    mutating func atom() throws -> UExpr {
        guard let t = peek() else { throw UParseError.unexpectedEnd }
        switch t {
        case .num(let v): pos += 1; return .num(v)
        case .lparen:
            pos += 1; let e = try addSub()
            guard peek() == .rparen else { throw UParseError.badToken("expected )") }
            pos += 1; return e
        case .ident(let name):
            pos += 1
            if uFunctions.contains(name), peek() == .lparen {
                pos += 1; let arg = try addSub()
                guard peek() == .rparen else { throw UParseError.badToken("expected )") }
                pos += 1; return .funcApp(name, arg)
            }
            return .sym(name)
        default: throw UParseError.badToken("unexpected token")
        }
    }
}
