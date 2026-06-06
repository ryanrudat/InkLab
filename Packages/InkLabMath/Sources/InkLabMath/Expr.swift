import Foundation

/// Parsed arithmetic/algebra expression. Supports +, −, ×, ÷, integer/parenthesised powers,
/// parentheses, unary minus, implicit multiplication ("2x", "2(x+1)", "(x+1)(x-1)"), rational and
/// decimal literals, and known function calls (sin, cos, √…) treated as opaque atoms.
public indirect enum Expr: Equatable, Sendable {
    case num(Rational)
    case variable(String)
    case neg(Expr)
    case add(Expr, Expr)
    case sub(Expr, Expr)
    case mul(Expr, Expr)
    case div(Expr, Expr)
    case pow(Expr, Expr)
    case funcApp(String, [Expr])
    case deriv(Expr, String)        // d/d<var>( inner )
}

public enum ParseError: Error, Equatable, Sendable {
    case empty
    case unexpectedCharacter(Character)
    case unexpectedToken(String)
    case unexpectedEnd
}

let knownFunctions: Set<String> = ["sin", "cos", "tan", "cot", "sec", "csc", "log", "ln", "exp", "sqrt", "abs"]

// MARK: - Tokenizer

enum Token: Equatable {
    case number(Rational)
    case ident(String)
    case plus, minus, star, slash, caret, lparen, rparen, comma
}

func tokenize(_ s: String) throws -> [Token] {
    var tokens: [Token] = []
    let chars = Array(s)
    var i = 0
    func isDigit(_ c: Character) -> Bool { c.isNumber }
    func isLetter(_ c: Character) -> Bool { c.isLetter }
    while i < chars.count {
        let c = chars[i]
        if c == " " || c == "\t" { i += 1; continue }
        if isDigit(c) || (c == "." && i + 1 < chars.count && isDigit(chars[i + 1])) {
            var intPart = 0, frac = 0, scale = 1, sawDot = false
            while i < chars.count, isDigit(chars[i]) || chars[i] == "." {
                if chars[i] == "." { if sawDot { throw ParseError.unexpectedCharacter(".") }; sawDot = true; i += 1; continue }
                let d = chars[i].wholeNumberValue ?? 0
                if sawDot { frac = frac * 10 + d; scale *= 10 } else { intPart = intPart * 10 + d }
                i += 1
            }
            tokens.append(.number(Rational(intPart * scale + frac, scale)))
            continue
        }
        if isLetter(c) {
            var name = ""
            while i < chars.count, isLetter(chars[i]) { name.append(chars[i]); i += 1 }
            tokens.append(.ident(name))
            continue
        }
        switch c {
        case "+": tokens.append(.plus)
        case "-", "\u{2212}": tokens.append(.minus)      // ASCII '-' and Unicode minus −
        case "*", "\u{00D7}", "\u{22C5}": tokens.append(.star)   // *, ×, ⋅
        case "/", "\u{00F7}": tokens.append(.slash)      // /, ÷
        case "^": tokens.append(.caret)
        case "(": tokens.append(.lparen)
        case ")": tokens.append(.rparen)
        case ",": tokens.append(.comma)
        default: throw ParseError.unexpectedCharacter(c)
        }
        i += 1
    }
    return tokens
}

// MARK: - Parser (recursive descent with implicit multiplication)

/// Parse a math expression. By default a multi-letter run is a PRODUCT of single-letter variables
/// ("xy" = x·y), which suits algebra. Pass `multiLetterVariables: true` for spreadsheet-style whole
/// names ("price", "taxRate") — used by the reactive engine.
public func parseExpr(_ s: String, multiLetterVariables: Bool = false) throws -> Expr {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { throw ParseError.empty }
    var p = Parser(tokens: try tokenize(trimmed), multiLetterVariables: multiLetterVariables)
    let e = try p.parseAddSub()
    guard p.atEnd else { throw ParseError.unexpectedToken("trailing input") }
    return e
}

struct Parser {
    let tokens: [Token]
    let multiLetterVariables: Bool
    var pos = 0
    init(tokens: [Token], multiLetterVariables: Bool = false) {
        self.tokens = tokens
        self.multiLetterVariables = multiLetterVariables
    }

    var atEnd: Bool { pos >= tokens.count }
    func peek() -> Token? { pos < tokens.count ? tokens[pos] : nil }
    mutating func advance() -> Token { defer { pos += 1 }; return tokens[pos] }
    mutating func match(_ t: Token) -> Bool { if peek() == t { pos += 1; return true }; return false }

    mutating func parseAddSub() throws -> Expr {
        var lhs = try parseMulDiv()
        while let t = peek(), t == .plus || t == .minus {
            pos += 1
            let rhs = try parseMulDiv()
            lhs = (t == .plus) ? .add(lhs, rhs) : .sub(lhs, rhs)
        }
        return lhs
    }

    mutating func parseMulDiv() throws -> Expr {
        var lhs = try parseUnary()
        loop: while let t = peek() {
            switch t {
            case .star: pos += 1; lhs = .mul(lhs, try parseUnary())
            case .slash: pos += 1; lhs = .div(lhs, try parseUnary())
            case .number, .ident, .lparen:          // juxtaposition => implicit multiplication
                lhs = .mul(lhs, try parseUnary())
            default: break loop
            }
        }
        return lhs
    }

    mutating func parseUnary() throws -> Expr {
        if let v = tryParseDerivativeOperator() { return .deriv(try parsePow(), v) }
        if match(.minus) { return .neg(try parseUnary()) }
        if match(.plus) { return try parseUnary() }
        return try parsePow()
    }

    /// Recognise the derivative operator "d/dx" (also d/dy, d/dt) as a prefix.
    mutating func tryParseDerivativeOperator() -> String? {
        guard pos + 2 < tokens.count, tokens[pos] == .ident("d"), tokens[pos + 1] == .slash,
              case .ident(let s) = tokens[pos + 2], s.count == 2, s.hasPrefix("d") else { return nil }
        pos += 3
        return String(s.dropFirst())
    }

    mutating func parsePow() throws -> Expr {
        let base = try parseAtom()
        if match(.caret) { return .pow(base, try parseUnary()) }   // right-associative
        return base
    }

    mutating func parseAtom() throws -> Expr {
        guard let t = peek() else { throw ParseError.unexpectedEnd }
        switch t {
        case .number(let r): pos += 1; return .num(r)
        case .lparen:
            pos += 1
            let e = try parseAddSub()
            guard match(.rparen) else { throw ParseError.unexpectedToken("expected )") }
            return e
        case .ident(let name):
            pos += 1
            if knownFunctions.contains(name), peek() == .lparen {
                pos += 1
                var args: [Expr] = [try parseAddSub()]
                while match(.comma) { args.append(try parseAddSub()) }
                guard match(.rparen) else { throw ParseError.unexpectedToken("expected ) after function args") }
                return .funcApp(name, args)
            }
            // Whole-word variable (spreadsheet mode) …
            if multiLetterVariables { return .variable(name) }
            // … or a product of single-letter variables (algebra mode: "xy" = x·y).
            let vars = name.map { Expr.variable(String($0)) }
            return vars.dropFirst().reduce(vars[0]) { .mul($0, $1) }
        default:
            throw ParseError.unexpectedToken("unexpected token")
        }
    }
}
