import Foundation

// The "red-pen tutor": read a chain of handwritten steps (already transcribed to strings by the
// recognizer) and deterministically find the FIRST line that doesn't follow from the one above —
// then explain why and, where possible, show a concrete counterexample. Understanding-first: it
// localizes and explains the error rather than just handing over the answer (brief §6.4).

public enum TutorErrorKind: Equatable, Sendable {
    case notEqual            // an expression-simplification step that isn't equal to the previous
    case solutionSetChanged  // an equation step that changes the set of solutions
}

public enum TutorVerdict: Equatable, Sendable {
    case allValid(steps: Int)
    /// `line` is the 1-based number of the first line that doesn't follow from the one above it.
    case firstError(line: Int, kind: TutorErrorKind, explanation: String, counterexample: String?)
    case unsupported(line: Int, reason: String)
    /// Line `line` isn't finished: nothing after its "=" ("1 + 3 =", "2x ="), or on line 1 nothing before
    /// it. Not a mistake and not unreadable; the lines above it were checked and follow.
    case unfinished(line: Int)
}

/// The first line the student hasn't finished, 1-based: one that ends with "=" (nothing on its right),
/// or line 1 starting with "=" (nothing on its left; later lines may start with "=" to continue the line
/// above). Blank lines are skipped, as `checkChain` does.
public func unfinishedLine(_ rawLines: [String]) -> Int? {
    let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    for (i, l) in lines.enumerated() where l.hasSuffix("=") || (i == 0 && l.hasPrefix("=")) {
        return i + 1
    }
    return nil
}

/// An unfinished line without its dangling "=" ("1 + 3 =" → "1 + 3"): the part the student did write.
public func withoutDanglingEquals(_ line: String) -> String {
    var s = line.trimmingCharacters(in: .whitespaces)
    if s.hasSuffix("=") { s = String(s.dropLast()).trimmingCharacters(in: .whitespaces) }
    else if s.hasPrefix("=") { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
    return s
}

/// The student's answer to an unfinished line as the finished line: "1 + 3 =" answered with "4" (or
/// "= 4") is "1 + 3 = 4"; "= 7" answered with "2x + 3" is "2x + 3 = 7". A whole line ("1 + 3 = 4") is
/// taken as written.
public func completingUnfinished(_ unfinished: String, with step: String) -> String {
    let u = unfinished.trimmingCharacters(in: .whitespaces), s = step.trimmingCharacters(in: .whitespaces)
    let body = s.hasPrefix("=") ? String(s.dropFirst()).trimmingCharacters(in: .whitespaces) : s
    guard !body.isEmpty, !body.contains("=") else { return s }
    let written = withoutDanglingEquals(u)
    if written.isEmpty { return body }
    return u.hasSuffix("=") ? "\(written) = \(body)" : "\(body) = \(written)"
}

enum LineForm: Equatable {
    case expression(Expr)                       // a bare expression (no '=')
    case continuation(Expr)                     // "= E"  (equals the previous expression)
    case equation(Expr, Expr)                   // L = R
    case integralClaim(Expr, String, Expr?)     // ∫ integrand dx  (with optional "= answer" on the same line)
}

func parseLine(_ raw: String) throws -> LineForm {
    let s = raw.trimmingCharacters(in: .whitespaces)
    if let sign = s.firstIndex(of: "∫") {
        var rem = String(s[s.index(after: sign)...]).trimmingCharacters(in: .whitespaces)
        var answer: Expr? = nil
        if let eq = rem.firstIndex(of: "=") {
            answer = try parseExpr(String(rem[rem.index(after: eq)...]))
            rem = String(rem[..<eq])
        }
        let (integrandStr, variable) = stripDifferential(rem)
        return .integralClaim(try parseExpr(integrandStr), variable, answer)
    }
    if s.hasPrefix("=") { return .continuation(try parseExpr(String(s.dropFirst()))) }
    if let idx = s.firstIndex(of: "=") {
        let lhs = String(s[s.startIndex..<idx]), rhs = String(s[s.index(after: idx)...])
        if rhs.contains("=") { throw ParseError.unexpectedToken("multiple '='") }
        return .equation(try parseExpr(lhs), try parseExpr(rhs))
    }
    return .expression(try parseExpr(s))
}

/// Split "f dx" into ("f", "x"); defaults the variable to x when no differential is present.
func stripDifferential(_ s: String) -> (String, String) {
    let chars = Array(s.trimmingCharacters(in: .whitespaces))
    if chars.count >= 2, chars[chars.count - 2] == "d", let last = chars.last, last.isLetter {
        let beforeIdx = chars.count - 3
        if beforeIdx < 0 || !chars[beforeIdx].isLetter {
            return (String(chars[0..<(chars.count - 2)]).trimmingCharacters(in: .whitespaces), String(last))
        }
    }
    return (String(chars), "x")
}

/// Check a worked chain. Two supported formats, chosen by the first line:
///  • equation chain — every line is `L = R`; consecutive steps must preserve the solution set.
///  • expression chain — first line is an expression; following lines are `= E` (or a bare
///    expression) and must each be exactly equal to the running value.
public func checkChain(_ rawLines: [String]) -> TutorVerdict {
    let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !lines.isEmpty else { return .unsupported(line: 0, reason: "no input") }
    // A line ending in "=" is a step the student hasn't finished, not one the parser can't read. The
    // lines above it are checked as usual, and a mistake there comes first.
    if let u = unfinishedLine(lines) {
        if u > 1 {
            let above = checkChain(Array(lines[..<(u - 1)]))
            if case .allValid = above {} else { return above }
        }
        return .unfinished(line: u)
    }

    var forms: [LineForm] = []
    for (i, l) in lines.enumerated() {
        do { forms.append(try parseLine(l)) }
        catch { return .unsupported(line: i + 1, reason: "couldn't read \"\(l)\"") }
    }
    // Note: no blanket "single line is fine" short-circuit — a one-line calculus claim like
    // "∫ x^2 dx = x^3/3 + C" or "d/dx(x^2) = 2x" is self-contained and MUST be verified. Each
    // checker handles the single-line case (a plain expression/equation with nothing to compare
    // against folds to allValid; an incomplete calculus claim folds to unsupported).
    switch forms[0] {
    case .integralClaim(let f, let v, let ans): return checkIntegral(f, v, ans, forms)
    case .equation(.deriv(let inner, let v), let rhs): return checkDerivative(inner, v, rhs, forms)
    case .expression(.deriv(let inner, let v)): return checkDerivative(inner, v, nil, forms)
    case .equation(let l, let r):
        if let wrong = falseArithmetic(l, r) { return wrong }
        return checkEquationChain(forms)
    case .expression: return checkExpressionChain(forms)
    case .continuation: return .unsupported(line: 1, reason: "a chain can't begin with '='")
    }
}

/// "1 + 3 = 5" has no unknowns, so it is simply false. An equation chain compares each line's solutions
/// with the line above, which can't see that on line 1 (there is nothing above it); later lines are
/// compared as usual ("x + 5 = x" → "5 = 0" is a fine step).
private func falseArithmetic(_ l: Expr, _ r: Expr) -> TutorVerdict? {
    let a = canonicalize(l), b = canonicalize(r)
    let sides = [a, b]
    guard sides.allSatisfy({ $0.num.atoms.isEmpty && $0.den.atoms.isEmpty && $0.isWellDefined && !$0.isOverflow }),
          !a.equals(b) else { return nil }
    return .firstError(line: 1, kind: .notEqual, explanation: "The two sides of line 1 aren't equal.", counterexample: nil)
}

// MARK: - Expression-simplification chain (consecutive values must be exactly equal)

private func checkExpressionChain(_ forms: [LineForm]) -> TutorVerdict {
    guard case .expression(let first) = forms[0] else { return .unsupported(line: 1, reason: "expected an expression") }
    let prev = canonicalize(first)
    guard prev.isWellDefined else { return .unsupported(line: 1, reason: "undefined (division by zero?)") }
    return continuationCheck(prev: prev, forms: forms, from: 1)
}

/// Shared loop: each following line must be exactly equal to the running value (with the
/// correct-or-silent guard — only accuse when we're certain, never on an unverifiable opaque step).
private func continuationCheck(prev start: RationalFunction, forms: [LineForm], from startIdx: Int) -> TutorVerdict {
    var prev = start
    for i in startIdx..<forms.count {
        let cur: Expr
        switch forms[i] {
        case .expression(let e), .continuation(let e): cur = e
        default: return .unsupported(line: i + 1, reason: "expected a continuation of the expression")
        }
        let rf = canonicalize(cur)
        guard rf.isWellDefined else { return .unsupported(line: i + 1, reason: "undefined (division by zero?)") }
        if prev.isOverflow || rf.isOverflow { return .unsupported(line: i + 1, reason: "numbers too large to verify exactly") }
        if !prev.equals(rf) {
            if hasOpaque(prev) || hasOpaque(rf) {
                return .unsupported(line: i + 1, reason: "contains functions/radicals I can't verify yet")
            }
            return .firstError(line: i + 1, kind: .notEqual,
                               explanation: "Line \(i + 1) isn't equal to line \(i).",
                               counterexample: equalityCounterexample(prev, rf))
        }
        prev = rf
    }
    return .allValid(steps: forms.count)
}

// MARK: - Calculus: verify a derivative or integral step deterministically

/// `d/dx(inner) = answer`. `rhsSameLine` is set when written on one line; otherwise the answer is the
/// next line. Verifies that the exact derivative equals the claimed result.
private func checkDerivative(_ inner: Expr, _ v: String, _ rhsSameLine: Expr?, _ forms: [LineForm]) -> TutorVerdict {
    let answer: Expr, answerLine: Int, contStart: Int
    if let rhs = rhsSameLine { answer = rhs; answerLine = 1; contStart = 1 }
    else {
        guard forms.count >= 2 else { return .unsupported(line: 1, reason: "the derivative needs a result line") }
        switch forms[1] {
        case .expression(let e), .continuation(let e): answer = e
        default: return .unsupported(line: 2, reason: "expected the derivative's result")
        }
        answerLine = 2; contStart = 2
    }
    let derivative = canonicalize(differentiate(inner, v)), ans = canonicalize(answer)
    guard derivative.isWellDefined, ans.isWellDefined else { return .unsupported(line: answerLine, reason: "undefined") }
    if derivative.isOverflow || ans.isOverflow { return .unsupported(line: answerLine, reason: "numbers too large to verify exactly") }
    if !derivative.equals(ans) {
        if hasOpaque(derivative) || hasOpaque(ans) { return .unsupported(line: answerLine, reason: "contains functions I can't differentiate yet") }
        return .firstError(line: answerLine, kind: .notEqual,
                           explanation: "This isn't the correct derivative.",
                           counterexample: equalityCounterexample(derivative, ans))
    }
    return continuationCheck(prev: ans, forms: forms, from: contStart)
}

/// `∫ integrand dx = answer`. Verified by differentiating the claimed antiderivative — its derivative
/// must equal the integrand. This handles "+C" automatically (a constant differentiates to 0).
private func checkIntegral(_ integrand: Expr, _ v: String, _ ansSameLine: Expr?, _ forms: [LineForm]) -> TutorVerdict {
    let answer: Expr, answerLine: Int, contStart: Int
    if let a = ansSameLine { answer = a; answerLine = 1; contStart = 1 }
    else {
        guard forms.count >= 2 else { return .unsupported(line: 1, reason: "the integral needs a result line") }
        switch forms[1] {
        case .expression(let e), .continuation(let e): answer = e
        default: return .unsupported(line: 2, reason: "expected the integral's result")
        }
        answerLine = 2; contStart = 2
    }
    let dAnswer = canonicalize(differentiate(answer, v)), f = canonicalize(integrand)
    guard dAnswer.isWellDefined, f.isWellDefined else { return .unsupported(line: answerLine, reason: "undefined") }
    if dAnswer.isOverflow || f.isOverflow { return .unsupported(line: answerLine, reason: "numbers too large to verify exactly") }
    if !dAnswer.equals(f) {
        if hasOpaque(dAnswer) || hasOpaque(f) { return .unsupported(line: answerLine, reason: "contains functions I can't integrate yet") }
        return .firstError(line: answerLine, kind: .notEqual,
                           explanation: "This isn't a correct antiderivative — its derivative doesn't match the integrand.",
                           counterexample: equalityCounterexample(dAnswer, f))
    }
    return continuationCheck(prev: canonicalize(answer), forms: forms, from: contStart)
}

// MARK: - Equation-solving chain (consecutive steps must preserve the solution set)

private func checkEquationChain(_ forms: [LineForm]) -> TutorVerdict {
    // Returns the "L − R" numerator, or a failure verdict (not an equation / undefined).
    func diff(_ form: LineForm, _ line: Int) -> (poly: Polynomial?, fail: TutorVerdict?) {
        guard case .equation(let l, let r) = form else {
            return (nil, .unsupported(line: line, reason: "expected an equation (L = R)"))
        }
        let d = canonicalize(l) - canonicalize(r)
        guard d.isWellDefined else { return (nil, .unsupported(line: line, reason: "undefined (division by zero?)")) }
        return (d.num, nil)
    }

    let first = diff(forms[0], 1)
    if let fail = first.fail { return fail }
    var prevPoly = first.poly!

    for i in 1..<forms.count {
        let cur = diff(forms[i], i + 1)
        if let fail = cur.fail { return fail }
        let curPoly = cur.poly!
        if prevPoly.isOverflow || curPoly.isOverflow { return .unsupported(line: i + 1, reason: "numbers too large to verify exactly") }
        if prevPoly.proportionalConstant(to: curPoly) == nil {
            if hasOpaque(prevPoly) || hasOpaque(curPoly) {
                return .unsupported(line: i + 1, reason: "contains functions/radicals I can't verify yet")
            }
            return .firstError(line: i + 1, kind: .solutionSetChanged,
                               explanation: "The step from line \(i) to line \(i + 1) changes the equation's solutions.",
                               counterexample: equationCounterexample(prevPoly, curPoly))
        }
        prevPoly = curPoly
    }
    return .allValid(steps: forms.count)
}

// MARK: - Counterexamples (single real variable; deterministic small search)

private func hasOpaqueAtoms(_ atoms: Set<String>) -> Bool { atoms.contains { !$0.allSatisfy(\.isLetter) } }
private func hasOpaque(_ rf: RationalFunction) -> Bool { hasOpaqueAtoms(rf.num.atoms.union(rf.den.atoms)) }
private func hasOpaque(_ p: Polynomial) -> Bool { hasOpaqueAtoms(p.atoms) }

private func soleVariable(_ atoms: Set<String>) -> String? {
    let simple = atoms.filter { $0.allSatisfy { $0.isLetter } }
    let opaque = atoms.subtracting(simple)
    guard opaque.isEmpty, simple.count == 1 else { return nil }
    return simple.first
}

private func equalityCounterexample(_ a: RationalFunction, _ b: RationalFunction) -> String? {
    let atoms = a.num.atoms.union(a.den.atoms).union(b.num.atoms).union(b.den.atoms)
    guard let v = soleVariable(atoms) else { return nil }
    for k in -5...5 {
        let env = [v: Rational(k)]
        let ad = a.den.evaluated(env), bd = b.den.evaluated(env)
        if ad.isZero || bd.isZero { continue }
        let av = a.num.evaluated(env) / ad, bv = b.num.evaluated(env) / bd
        if av != bv {
            return "At \(v) = \(k), the line above equals \(av) but this line equals \(bv)."
        }
    }
    return nil
}

private func equationCounterexample(_ prev: Polynomial, _ cur: Polynomial) -> String? {
    let atoms = prev.atoms.union(cur.atoms)
    guard let v = soleVariable(atoms) else { return nil }
    for k in -10...10 {
        let env = [v: Rational(k)]
        let solvesPrev = prev.evaluated(env).isZero
        let solvesCur = cur.evaluated(env).isZero
        if solvesPrev && !solvesCur {
            return "\(v) = \(k) is a solution of line above but no longer satisfies this line — a solution was lost."
        }
        if !solvesPrev && solvesCur {
            return "\(v) = \(k) satisfies this line but not the line above — this step introduced an extra solution."
        }
    }
    return nil
}

// MARK: - Convenience for tests / engines

/// Exact equivalence of two expression strings (true mathematical equality, not string match).
/// Throws `ParseError.numberTooLarge` if either side overflows exact arithmetic, so callers degrade
/// (try?/catch) rather than receiving a wrong answer.
public func areEquivalent(_ a: String, _ b: String) throws -> Bool {
    let ca = canonicalize(try parseExpr(a)), cb = canonicalize(try parseExpr(b))
    if ca.isOverflow || cb.isOverflow { throw ParseError.numberTooLarge }
    return ca.equals(cb)
}
