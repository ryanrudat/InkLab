import Foundation
import InkLabKit

/// The deterministic engines, surfaced to the UI as plain `String -> String` calls so both the
/// "@" command bar and the recognition review chips share one correct-by-construction path.
/// Everything here is on-device and exact; nothing calls the network.

/// The engine actions offered as chips on a recognized selection.
enum EngineAction: String, CaseIterable, Identifiable {
    case check        = "Check working"
    case differentiate = "Differentiate"
    case units        = "Units"
    case balance      = "Balance"
    case molarMass    = "Molar mass"
    case dna          = "DNA → Protein"
    case punnett      = "Punnett"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .check:        return "checkmark.seal"
        case .differentiate: return "function"
        case .units:        return "ruler"
        case .balance:      return "scalemass"
        case .molarMass:    return "atom"
        case .dna:          return "allergens"
        case .punnett:      return "square.grid.2x2"
        }
    }
}

func runEngine(_ action: EngineAction, on text: String) -> String {
    switch action {
    case .check:        return redPen(text)
    case .differentiate: return differentiateText(text)
    case .units:        return checkUnits(text)
    case .balance:      return balanceEquation(text)
    case .molarMass:    return molarMassText(text)
    case .dna:          return dnaToProtein(text)
    case .punnett:      return punnettCross(text)
    }
}

// MARK: - Individual engines (shared by the @-bar and the chips)

/// Red-pen tutor: read a chain of worked steps and mark the first line that doesn't follow.
func redPen(_ text: String) -> String {
    let lines = splitSteps(text)
    guard !lines.isEmpty else { return "Write some working first (one step per line)." }
    return renderVerdict(checkChain(lines))
}

/// Exact symbolic derivative. Accepts "x^2" or "x^2, t" (variable after a comma; defaults to x).
func differentiateText(_ raw: String) -> String {
    var exprStr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    var v = "x"
    if let comma = exprStr.lastIndex(of: ",") {
        let after = exprStr[exprStr.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        if after.count == 1, let c = after.first, c.isLetter {
            v = after
            exprStr = String(exprStr[..<comma]).trimmingCharacters(in: .whitespaces)
        }
    }
    guard !exprStr.isEmpty else { return "Nothing to differentiate." }
    do {
        let e = try parseExpr(exprStr)
        let d = simplify(differentiate(e, v))
        return "d/d\(v) (\(exprStr)) = \(renderExpr(d))"
    } catch {
        return "Couldn't read \"\(exprStr)\" as an expression."
    }
}

func checkUnits(_ text: String) -> String {
    let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return "Enter a units expression, e.g. 5 m + 3 s." }
    let verdict = s.contains("=") ? checkEquation(s) : checkExpression(s)
    switch verdict {
    case .consistent(let d): return "✓ \(s) → \(d.symbol)"
    case .mismatch(let m):   return "✗ \(m)"
    case .unsupported(let u): return "… \(u)"
    }
}

func balanceEquation(_ text: String) -> String {
    switch balance(text) {
    case .balanced(let b):       return b.pretty
    case .cannotBalance(let r):  return "Can't balance — \(r)"
    case .unsupported(let r):    return "Couldn't read that — \(r)"
    }
}

func molarMassText(_ text: String) -> String {
    let f = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let m = molarMass(f) { return "\(f) = \(String(format: "%.3f", m)) g/mol" }
    return "Unknown formula: \(f)"
}

/// @dna chip / DNA→Protein: the full coding-DNA → protein chain.
func dnaToProtein(_ text: String) -> String {
    let dna = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if let t = translateDNA(coding: dna) {
        return "\(dna) → protein \(t.peptide)\(t.reachedStop ? " (stop)" : "")"
    }
    return "Not valid DNA: \(dna)"
}

/// @transcribe: coding DNA → mRNA (T → U). NOT the same as @translate — this stops at mRNA.
func transcribeText(_ text: String) -> String {
    let dna = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !dna.isEmpty else { return "Enter a DNA sequence, e.g. ATGGCC." }
    if let mRNA = transcribe(coding: dna) { return "\(dna) → mRNA \(mRNA)" }
    return "Not valid DNA: \(dna)"
}

/// @translate: mRNA → protein (peptide up to the first stop codon). Accepts RNA bases (A,C,G,U).
func mRNAToProtein(_ text: String) -> String {
    let mRNA = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !mRNA.isEmpty else { return "Enter an mRNA sequence, e.g. AUGGCC." }
    if let t = translate(mRNA) {
        return "\(mRNA) → protein \(t.peptide)\(t.reachedStop ? " (stop)" : "")"
    }
    return "Not valid mRNA: \(mRNA)"
}

func punnettCross(_ text: String) -> String {
    let parts = text.replacingOccurrences(of: "×", with: " x ")
        .components(separatedBy: " x ")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    if parts.count == 2, let c = punnett(parts[0], parts[1]) {
        let ratio = c.phenotypes.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: " : ")
        return "\(parts[0]) × \(parts[1]) → \(ratio)  (of \(c.total))"
    }
    return "Use e.g. Aa x Aa"
}

// MARK: - Rendering helpers

private func splitSteps(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == "\n" || $0 == ";" })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

private func renderVerdict(_ v: TutorVerdict) -> String {
    switch v {
    case .allValid(let steps):
        return "✓ All \(steps) step\(steps == 1 ? "" : "s") check out."
    case .firstError(let line, let kind, let explanation, let counterexample):
        let what = kind == .notEqual ? "isn't equal to the line above" : "changes the solution set"
        var msg = "✗ Line \(line) \(what). \(explanation)"
        if let ce = counterexample { msg += " (e.g. \(ce))" }
        return msg
    case .unsupported(let line, let reason):
        return "… Couldn't check line \(line): \(reason)"
    }
}

// MARK: - Expr simplification + rendering (for the differentiate result)

/// A small fixed-point-free simplifier: constant folding plus ×1 / ×0 / +0 / ^1 / ^0 identities.
/// Enough to turn a raw power-rule result like 2·x^1·1 into a clean 2x.
private func simplify(_ e: Expr) -> Expr {
    switch e {
    case .num, .variable:
        return e
    case .neg(let a):
        let sa = simplify(a)
        if case .num(let r) = sa { return .num(-r) }
        return .neg(sa)
    case .add(let a, let b):
        let sa = simplify(a), sb = simplify(b)
        if case .num(let x) = sa, case .num(let y) = sb { return .num(x + y) }
        if isZero(sa) { return sb }
        if isZero(sb) { return sa }
        return .add(sa, sb)
    case .sub(let a, let b):
        let sa = simplify(a), sb = simplify(b)
        if case .num(let x) = sa, case .num(let y) = sb { return .num(x - y) }
        if isZero(sb) { return sa }
        if isZero(sa) { return simplify(.neg(sb)) }   // 0 - b => -b (the quotient rule leaks these)
        return .sub(sa, sb)
    case .mul(let a, let b):
        let sa = simplify(a), sb = simplify(b)
        if case .num(let x) = sa, case .num(let y) = sb { return .num(x * y) }
        if isZero(sa) || isZero(sb) { return .num(.zero) }
        if isOne(sa) { return sb }
        if isOne(sb) { return sa }
        return .mul(sa, sb)
    case .div(let a, let b):
        let sa = simplify(a), sb = simplify(b)
        if isZero(sa) { return .num(.zero) }
        if isOne(sb) { return sa }
        return .div(sa, sb)
    case .pow(let base, let exp):
        let sBase = simplify(base), sExp = simplify(exp)
        if case .num(let r) = sExp {
            if r == .one { return sBase }
            if r == .zero { return .num(.one) }
        }
        return .pow(sBase, sExp)
    case .funcApp(let name, let args):
        return .funcApp(name, args.map(simplify))
    case .deriv(let inner, let v):
        return .deriv(simplify(inner), v)
    }
}

private func isZero(_ e: Expr) -> Bool { if case .num(let r) = e { return r.isZero }; return false }
private func isOne(_ e: Expr) -> Bool { if case .num(let r) = e { return r == .one }; return false }

/// Precedence-aware rendering. A child is wrapped in parentheses whenever its binding precedence is
/// looser than the position requires, so a power/quotient base like (2x)^2 or a/(b/c) never collapses
/// into a different value (which a naive renderer would, e.g. printing -2/(2x)^2 as the wrong -2/2x^2).
private func renderExpr(_ e: Expr) -> String { render(e).text }

/// Binding tightness: higher binds tighter. A leading-minus number behaves like a low-precedence
/// term so it gets parenthesized in binary positions ("x - (-3)", "x^(-1)").
private func precedence(_ e: Expr) -> Int {
    switch e {
    case .num(let r):      return r.description.hasPrefix("-") ? 5 : 40
    case .variable, .funcApp, .deriv: return 40
    case .pow:             return 30
    case .neg:             return 25
    case .mul, .div:       return 20
    case .add, .sub:       return 10
    }
}

private func wrap(_ e: Expr, _ minPrecedence: Int) -> String {
    let r = render(e)
    return r.prec < minPrecedence ? "(\(r.text))" : r.text
}

private func render(_ e: Expr) -> (text: String, prec: Int) {
    let p = precedence(e)
    switch e {
    case .num(let r):      return (r.description, p)
    case .variable(let v): return (v, p)
    case .neg(let a):      return ("-\(wrap(a, 26))", p)
    case .add(let a, let b): return ("\(wrap(a, 10)) + \(wrap(b, 10))", p)
    case .sub(let a, let b): return ("\(wrap(a, 10)) - \(wrap(b, 11))", p)
    case .mul(let a, let b):
        if case .num = a, case .variable = b { return ("\(wrap(a, 20))\(wrap(b, 20))", p) }  // 2x, not 2·x
        return ("\(wrap(a, 20))·\(wrap(b, 21))", p)
    case .div(let a, let b): return ("\(wrap(a, 20))/\(wrap(b, 21))", p)
    case .pow(let base, let exp): return ("\(wrap(base, 31))^\(wrap(exp, 26))", p)
    case .funcApp(let name, let args):
        let inner = args.map(renderExpr).joined(separator: ", ")
        return (name == "∂" ? "∂(\(inner))" : "\(name)(\(inner))", p)
    case .deriv(let inner, let v): return ("d/d\(v)(\(renderExpr(inner)))", p)
    }
}
