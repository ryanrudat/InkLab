import Foundation

// Engine support for the Socratic tutor (InkLab app `Tutor.swift`, proxy `POST /tutor`).
//
// The tutor talks; this engine decides. Two jobs live here because they need the exact algebra:
//  1. `problemFacts` — what the tutor must never hand over, derived from the problem (line 1): its
//     value, its solution set, the exact derivative, or (for an integral) the integrand whose
//     antiderivatives are all protected.
//  2. `tutorReplyLeak` — the app's own answer-leak check of a tutor reply, by EXACT equivalence (the
//     same canonical forms the red pen uses), not string match. The proxy runs a numeric version of the
//     same check first; this is defence in depth on the device.

public enum ChainKind: String, Sendable, Equatable {
    case expression, equation, derivative, integral
}

/// A result the tutor must never state (or any form mathematically equivalent to it).
public enum ProtectedResult: Equatable, Sendable {
    /// The problem's value (an expression chain) or the exact derivative (a derivative claim).
    case expression(Expr)
    /// The problem equation: a rearrangement of it, or a value that solves it, gives the answer away.
    case equation(Expr, Expr)
    /// The integrand: any expression whose derivative is the integrand is a correct antiderivative.
    case antiderivative(integrand: Expr, variable: String)
}

public struct ProblemFacts: Equatable, Sendable {
    public let chain: ChainKind
    public let protected: [ProtectedResult]
}

/// What the tutor must protect for this working, from its first line. nil when line 1 can't be read
/// (then there is nothing to check a reply against, and the proxy answers without a model call).
/// An unfinished line 1 ("1 + 3 =") is read without its dangling "=", so its value is protected; an
/// arithmetic line ("1 + 3 = 4") is an expression being worked out, not an equation to solve.
public func problemFacts(_ rawLines: [String]) -> ProblemFacts? {
    let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard let first = lines.first.map({ $0.hasSuffix("=") ? withoutDanglingEquals($0) : $0 }),
          let form = try? parseLine(first) else { return nil }
    if case .equation(let l, let r) = form, isArithmetic(l), isArithmetic(r) {
        return ProblemFacts(chain: .expression, protected: [.expression(l)])
    }
    switch form {
    case .integralClaim(let f, let v, _):
        return ProblemFacts(chain: .integral, protected: [.antiderivative(integrand: f, variable: v)])
    case .equation(.deriv(let inner, let v), _), .expression(.deriv(let inner, let v)):
        return ProblemFacts(chain: .derivative, protected: [.expression(differentiate(inner, v))])
    case .equation(let l, let r):
        return ProblemFacts(chain: .equation, protected: [.equation(l, r)])
    case .expression(let e):
        return ProblemFacts(chain: .expression, protected: [.expression(e)])
    case .continuation:
        return nil
    }
}

private func isArithmetic(_ e: Expr) -> Bool {
    let rf = canonicalize(e)
    return rf.num.atoms.isEmpty && rf.den.atoms.isEmpty
}

// MARK: - Exact "does this give the answer away?"

private func usable(_ rf: RationalFunction) -> Bool { rf.isWellDefined && !rf.isOverflow }
private func hasUnknownDerivative(_ rf: RationalFunction) -> Bool {
    rf.num.atoms.union(rf.den.atoms).contains { $0.contains("∂") }
}

/// True when the expression `c` equals a protected value (or is an antiderivative of a protected
/// integrand). Exact; anything the engine can't decide (overflow, undefined) counts as "no".
public func revealsExpression(_ c: Expr, _ result: ProtectedResult) -> Bool {
    switch result {
    case .expression(let t):
        let a = canonicalize(c), b = canonicalize(t)
        guard usable(a), usable(b), !hasUnknownDerivative(b) else { return false }
        return a.equals(b)
    case .antiderivative(let f, let v):
        let rc = canonicalize(c)
        guard usable(rc), rc.num.atoms.union(rc.den.atoms).contains(v) else { return false }
        let d = canonicalize(differentiate(c, v)), g = canonicalize(f)
        guard usable(d), usable(g), !hasUnknownDerivative(d) else { return false }
        return d.equals(g)
    case .equation:
        return false
    }
}

/// True when the equation `l = r` is the protected equation rearranged by legal moves (its L − R
/// numerator is a nonzero constant multiple — exactly the red pen's step rule), or states a value that
/// solves it ("x = 2"). An identity such as "2x = 2x" says nothing and is not a leak.
public func revealsEquation(_ l: Expr, _ r: Expr, _ result: ProtectedResult) -> Bool {
    guard case .equation(let tl, let tr) = result else { return false }
    let d1 = canonicalize(l) - canonicalize(r), d2 = canonicalize(tl) - canonicalize(tr)
    guard usable(d1), usable(d2), !d1.num.isZero else { return false }
    if d1.num.proportionalConstant(to: d2.num) != nil { return true }
    for (side, value) in [(l, r), (r, l)] {
        guard case .variable(let v) = side, d2.num.atoms == [v], let c = constantRational(value), !c.isOverflow else { continue }
        let env = [v: c]
        let n = d2.num.evaluated(env), d = d2.den.evaluated(env)
        if n.isZero, !d.isZero, !n.isOverflow { return true }
    }
    return false
}

// MARK: - Finding the math in a prose reply (mirrors Server/src/mathGuard.ts)

/// The math in a tutor reply: expressions, and equations split at "=".
public enum ReplyMath: Equatable, Sendable {
    case expression(text: String, Expr)
    case equation(text: String, Expr, Expr)

    public var text: String {
        switch self { case .expression(let t, _), .equation(let t, _, _): return t }
    }
}

private let tutorFunctions: Set<String> = knownFunctions

/// Map Unicode math, light LaTeX and "x is 4" phrasing onto the parser's ASCII grammar, and drop line /
/// step references ("line 3"), which are never math.
public func normalizeTutorMath(_ raw: String) -> String {
    var s = raw
    func sub(_ pattern: String, _ template: String, _ options: NSRegularExpression.Options = []) {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
    sub(#"\\[()\[\]]"#, " "); sub("[`$]", " ")
    for _ in 0..<4 { sub(#"\\[dt]?frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}"#, "(($1)/($2))") }
    sub(#"\\sqrt\s*\{([^{}]*)\}"#, "sqrt($1)")
    sub(#"\\(cdot|times|ast)"#, "*"); sub(#"\\div"#, "/"); sub(#"\\(left|right)"#, "")
    sub(#"\\(sin|cos|tan|cot|sec|csc|log|ln|exp|pi)\b"#, "$1")
    sub(#"\{"#, "("); sub(#"\}"#, ")")
    sub("[\u{2212}\u{2013}\u{2012}\u{2010}]", "-"); sub("[×·⋅∙✕]", "*"); sub("÷", "/")
    sub("π", "pi"); sub(#"√\s*\("#, "sqrt("); sub(#"√\s*([0-9a-zA-Z.]+)"#, "sqrt($1)")
    // Superscripts: x² → x^2, x¹⁰ → x^(10).
    let sup: [Character: Character] = ["⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9", "⁻": "-"]
    var out = ""; var run = ""
    func flush() { if !run.isEmpty { out += run.count > 1 ? "^(\(run))" : "^\(run)"; run = "" } }
    for ch in s { if let d = sup[ch] { run.append(d) } else { flush(); out.append(ch) } }
    flush(); s = out
    sub(#"\b([a-zA-Z])\s+(?:is equal to|equals|is|should be|must be|would be|will be)\s+(?=[-(0-9.])"#, "$1 = ")
    sub(#"\bequals\b"#, "=", .caseInsensitive)
    sub(#"\b([a-zA-Z])\s*=\s*±\s*([0-9.]+)"#, "$1 = $2 or $1 = -$2")
    for _ in 0..<3 { sub(#"\b([a-zA-Z])\s*=\s*(-?[0-9.]+(?:/[0-9.]+)?)\s*(?:,|or|and)\s*(-?[0-9.]+(?:/[0-9.]+)?)\b"#, "$1 = $2 or $1 = $3") }
    sub(#"\b(lines?|steps?|hints?|levels?|rows?|parts?|questions?|problems?|examples?|rules?|pages?)\s+\d+(?:\s*(?:,|and|to|or|-|&)\s*\d+)*"#, "$1", .caseInsensitive)
    sub(#"\b\d+(st|nd|rd|th)\b"#, " ", .caseInsensitive)
    // Contractions are prose: "it's 4" must not glue a stray "s" onto the math.
    sub(#"([A-Za-z])['’](?:s|t|m|re|ve|d|ll)\b"#, "$1")
    return s
}

/// Comparison key for "the student wrote this": whitespace and `*` dropped, lower-cased.
public func tutorMathKey(_ s: String) -> String {
    String(s.filter { !$0.isWhitespace && $0 != "*" }).lowercased()
}
private func withoutConstant(_ key: String) -> String {
    key.hasSuffix("+c") || key.hasSuffix("+k") ? String(key.dropLast(2)) : key
}

private func isMathyToken(_ tok: String) -> Bool {
    let allowed = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ+-*/^=().")
    guard !tok.isEmpty, tok.unicodeScalars.allSatisfy(allowed.contains) else { return false }
    if tok.count == 1, tok.first!.isLetter { return true }
    let pureAlpha = tok.allSatisfy(\.isLetter)
    var runs: [String] = []; var cur = ""
    for ch in tok { if ch.isLetter { cur.append(ch) } else if !cur.isEmpty { runs.append(cur); cur = "" } }
    if !cur.isEmpty { runs.append(cur) }
    for r in runs {
        let lower = r.lowercased()
        if tutorFunctions.contains(lower) || lower == "pi" { continue }
        if pureAlpha || r.count >= 3 { return false }
    }
    return true
}

/// Every piece of math in a prose reply: maximal runs of math-looking tokens, split at "=". A run that
/// doesn't parse as a whole is retried window by window, so a leak can't hide behind a junk token.
public func extractTutorMath(_ text: String) -> [ReplyMath] {
    var s = normalizeTutorMath(text)
    for p in [",", ";", ":", "!", "?", "\"", "'", "“", "”", "‘", "’", "<", ">", "≤", "≥", "≠", "≈", "→", "←", "⇒"] {
        s = s.replacingOccurrences(of: p, with: " | ")
    }
    let tokens = s.split(whereSeparator: \.isWhitespace).map { tok -> String in
        var t = String(tok); while t.hasSuffix(".") { t.removeLast() }; return t
    }.filter { !$0.isEmpty }
    var runs: [[String]] = []; var current: [String] = []
    for tok in tokens {
        if tok != "|", isMathyToken(tok) { current.append(tok) } else { if !current.isEmpty { runs.append(current) }; current = [] }
    }
    if !current.isEmpty { runs.append(current) }
    // "is a 3x + 1", "I x = 2": an article-like single letter next to the math is prose, unless an
    // operator binds it ("a = 3", "x + a").
    let articles: Set<String> = ["a", "A", "I"], ops = "+-*/^="
    for k in runs.indices {
        while runs[k].count > 1, articles.contains(runs[k][0]), !(runs[k][1].first.map { ops.contains($0) } ?? false) { runs[k].removeFirst() }
        while runs[k].count > 1, articles.contains(runs[k][runs[k].count - 1]),
              !(runs[k][runs[k].count - 2].last.map { ops.contains($0) } ?? false) { runs[k].removeLast() }
    }

    var out: [ReplyMath] = []; var seen = Set<String>()
    func parse(_ p: String) -> Expr? { try? parseExpr(p) }
    func push(_ m: ReplyMath, _ key: String) { if seen.insert(key).inserted { out.append(m) } }
    @discardableResult func add(_ raw: String) -> Bool {
        var t = raw.trimmingCharacters(in: .whitespaces)
        while let f = t.first, "+*/^=".contains(f) { t.removeFirst() }
        while let l = t.last, "+-*/^=".contains(l) { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return true }
        let parts = t.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let exprs = parts.map(parse)
        if parts.count >= 2 {
            for i in 0..<(parts.count - 1) {
                if let l = exprs[i], let r = exprs[i + 1] {
                    push(.equation(text: "\(parts[i]) = \(parts[i + 1])", l, r), "eq:" + tutorMathKey("\(parts[i])=\(parts[i + 1])"))
                }
            }
        }
        for (i, p) in parts.enumerated() { if let e = exprs[i] { push(.expression(text: p, e), "ex:" + tutorMathKey(p)) } }
        return exprs.allSatisfy { $0 != nil }
    }
    for run in runs {
        if add(run.joined(separator: " ")) || run.count < 2 { continue }
        for i in 0..<run.count {
            for j in (i + 1)...min(run.count, i + 12) { add(run[i..<j].joined(separator: " ")) }
        }
    }
    return out
}

/// Comparison keys for everything the student wrote, so quoting their own work back is allowed.
public func studentMathKeys(_ texts: [String]) -> Set<String> {
    var keys = Set<String>()
    for t in texts {
        let whole = tutorMathKey(normalizeTutorMath(t))
        keys.insert(whole); keys.insert(withoutConstant(whole))
        for m in extractTutorMath(t) {
            let k = keyOf(m)
            keys.insert(k); keys.insert(withoutConstant(k))
        }
    }
    return keys
}

private func keyOf(_ m: ReplyMath) -> String {
    switch m {
    case .expression(let t, _): return tutorMathKey(t)
    case .equation(let t, _, _): return tutorMathKey(t)
    }
}

/// The first piece of math in a tutor reply that gives away a protected result (exact check), or nil.
public func tutorReplyLeak(_ reply: String, protected: [ProtectedResult], studentWrote: Set<String>) -> String? {
    for m in extractTutorMath(reply) {
        let key = keyOf(m)
        if studentWrote.contains(key) || studentWrote.contains(withoutConstant(key)) { continue }
        for result in protected {
            switch m {
            case .expression(let text, let e): if revealsExpression(e, result) { return text }
            case .equation(let text, let l, let r): if revealsEquation(l, r, result) { return text }
            }
        }
    }
    return nil
}

// MARK: - Rendering for the proxy's guard

/// Unambiguous ASCII for the proxy (explicit `*`, every compound operand parenthesized). nil when the
/// expression holds something the proxy can't read (an unknown-derivative marker, a nested d/dx).
public func renderTutorASCII(_ e: Expr) -> String? {
    switch e {
    case .num(let r):
        guard !r.isOverflow else { return nil }
        return r.isInteger && r.num >= 0 ? r.description : "(\(r.description))"
    case .variable(let v): return v
    case .neg(let a): return renderTutorASCII(a).map { "(-\($0))" }
    case .add(let a, let b): return bin(a, "+", b)
    case .sub(let a, let b): return bin(a, "-", b)
    case .mul(let a, let b): return bin(a, "*", b)
    case .div(let a, let b): return bin(a, "/", b)
    case .pow(let a, let b): return bin(a, "^", b)
    case .funcApp(let name, let args):
        guard tutorFunctions.contains(name), args.count == 1, let inner = renderTutorASCII(args[0]) else { return nil }
        return "\(name)(\(inner))"
    case .deriv:
        return nil
    }
}

private func bin(_ a: Expr, _ op: String, _ b: Expr) -> String? {
    guard let l = renderTutorASCII(a), let r = renderTutorASCII(b) else { return nil }
    return "(\(l)\(op)\(r))"
}
