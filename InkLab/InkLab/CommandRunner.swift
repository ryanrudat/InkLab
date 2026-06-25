import Foundation
import InkLabKit

/// Runs an "@" command by routing it (InkLabRouter) and invoking the matching deterministic engine,
/// returning a human-readable result. This is what makes the engines tangible in the app: type
/// "@balance H2 + O2 -> H2O" and get the balanced equation, etc.
func runCommand(_ raw: String) -> String {
    // `molar` / `molar mass` isn't one of InkLabRouter's verbs, so detect it here and route to chem.
    let head = raw.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "@" })
        .lowercased()
    let intent: Intent = head.hasPrefix("molar") ? .molarMass : parseCommand(raw)
    let arg = commandArgument(raw, intent: intent)

    switch intent {
    case .balance:                 return balanceEquation(arg)
    case .molarMass:               return molarMassText(arg)
    case .units:                   return checkUnits(arg)
    case .transcribe:              return transcribeText(arg)   // DNA → mRNA
    case .translate:               return mRNAToProtein(arg)    // mRNA → protein
    case .punnett:                 return punnettCross(arg)
    case .checkWork:               return redPen(arg)
    case .differentiate:           return differentiateText(arg)
    case .solve, .graph, .integrate:
        return "Use @check to mark working, @differentiate x^2 for derivatives, or @balance / @molar / @units / @transcribe / @punnett. (General solve / graph / integrate are on the roadmap.)"
    case .scientificCalculator:
        return "Scientific calculator (native widget) — on the roadmap."
    case .makeReal(let p): return "Make-real: “\(p)” — needs the optional AI backend (Server/)."
    case .explain(let q):  return "Explain: “\(q)” — needs the optional AI backend."
    case .quiz(let t):     return "Quiz on \(t) — needs the optional AI backend."
    case .animate(let s):  return "Animate \(s) — needs the optional AI backend."
    case .unknown:         return "Try: @check · @differentiate x^2 · @balance H2 + O2 -> H2O · @molar C6H12O6 · @units 5 m + 3 s · @transcribe ATGGCC · @punnett Aa x Aa"
    }
}

/// True for the deterministic engine verbs whose answers must be correct-by-construction (so they go
/// to an exact engine, not generation). Shared by the typed "@" bar and handwritten "@" commands.
func isDeterministicEngineCommand(_ raw: String) -> Bool {
    let head = raw.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "@" }).lowercased()
    if head.hasPrefix("molar") { return true }
    switch parseCommand(raw) {
    case .balance, .units, .transcribe, .translate, .punnett, .checkWork, .differentiate: return true
    default: return false
    }
}

/// The make-real prompt for a raw command — drops a leading "@" so Claude gets "a pendulum", not "@a pendulum".
func makeRealPrompt(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("@") { s.removeFirst() }
    return s.trimmingCharacters(in: .whitespaces)
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
