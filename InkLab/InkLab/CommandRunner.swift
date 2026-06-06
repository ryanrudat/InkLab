import Foundation
import InkLabKit

/// Runs an "@" command by routing it (InkLabRouter) and invoking the matching deterministic engine,
/// returning a human-readable result. This is what makes the engines tangible in the app: type
/// "@balance H2 + O2 -> H2O" and get the balanced equation, etc.
func runCommand(_ raw: String) -> String {
    let intent = parseCommand(raw)
    let arg = commandArgument(raw, intent: intent)

    switch intent {
    case .balance:
        switch balance(arg) {
        case .balanced(let b): return b.pretty
        case .cannotBalance(let r): return "Can't balance — \(r)"
        case .unsupported(let r): return "Couldn't read that — \(r)"
        }
    case .molarMass:
        if let m = molarMass(arg) { return "\(arg) = \(String(format: "%.3f", m)) g/mol" }
        return "Unknown formula: \(arg)"
    case .units:
        switch checkExpression(arg) {
        case .consistent(let d): return "✓ \(arg) → \(d.symbol)"
        case .mismatch(let m): return "✗ \(m)"
        case .unsupported(let u): return "… \(u)"
        }
    case .transcribe, .translate:
        if let t = translateDNA(coding: arg) { return "\(arg) → protein \(t.peptide)\(t.reachedStop ? " (stop)" : "")" }
        return "Not valid DNA: \(arg)"
    case .punnett:
        let parts = arg.replacingOccurrences(of: "×", with: " x ")
            .components(separatedBy: " x ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.count == 2, let c = punnett(parts[0], parts[1]) {
            let ratio = c.phenotypes.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: " : ")
            return "\(parts[0]) × \(parts[1]) → \(ratio)  (of \(c.total))"
        }
        return "Use e.g. @punnett Aa x Aa"
    case .solve, .graph, .differentiate, .integrate, .checkWork:
        // These act on selected handwriting; the @bar handles single-expression cases via areEquivalent.
        return "Select your working and use the action chips, or try @balance / @molar / @units / @transcribe."
    case .scientificCalculator:
        return "Scientific calculator (native widget) — wiring next."
    case .makeReal(let p): return "Make-real: “\(p)” — needs the AI backend (Server/) + API key."
    case .explain(let q):  return "Explain: “\(q)” — needs the AI backend."
    case .quiz(let t):     return "Quiz on \(t) — needs the AI backend."
    case .animate(let s):  return "Animate \(s) — needs the AI backend."
    case .unknown:         return "Try: @balance H2 + O2 -> H2O · @molar C6H12O6 · @units 5 m + 3 s · @transcribe ATGGCC"
    }
}

/// The text after the command verb (e.g. "@balance H2 + O2 -> H2O" → "H2 + O2 -> H2O").
private func commandArgument(_ raw: String, intent: Intent) -> String {
    var s = raw.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("@") { s.removeFirst() }
    s = s.trimmingCharacters(in: .whitespaces)
    // drop the leading verb word(s)
    let parts = s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    var rest = parts.count > 1 ? String(parts[1]) : ""
    // "molar mass C6H12O6" → drop a leading "mass"
    if case .molarMass = intent, rest.lowercased().hasPrefix("mass ") { rest = String(rest.dropFirst(5)) }
    return rest.trimmingCharacters(in: .whitespaces)
}
