import Foundation
import InkLabRecognition

/// What the user is asking for (from an "@" command or an action chip).
public enum Intent: Equatable, Sendable {
    case solve, graph, checkWork, differentiate, integrate, units
    case balance, molarMass
    case transcribe, translate, punnett
    case scientificCalculator
    case makeReal(String)
    case animate(String)
    case explain(String)
    case quiz(String)
    case unknown(String)
}

/// How an intent is fulfilled — the §4.3 reliability pattern. Known/domain work goes to a vetted
/// deterministic engine or native widget; novel work is generated (make-real) then verified.
public enum Dispatch: Equatable, Sendable {
    case deterministic(engine: String, action: String)   // correct by construction
    case native(widget: String)                          // vetted native render (e.g. calculator)
    case generative(prompt: String)                      // best-effort, then validated/sandboxed
}

// MARK: - The "@" ask-marker parser

/// Parse an "@" command (the universal AI invocation, §5.3) into an `Intent`. The leading "@" is
/// optional. Anything not matching a specific interpreter becomes a general make-real / explain.
public func parseCommand(_ raw: String) -> Intent {
    var s = raw.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("@") { s.removeFirst() }
    s = s.trimmingCharacters(in: .whitespaces)
    guard !s.isEmpty else { return .unknown("") }
    let lower = s.lowercased()
    let firstWord = lower.split(separator: " ").first.map(String.init) ?? lower
    let rest = restAfterFirstWord(s)

    if lower.contains("calculator") || lower == "calc" { return .scientificCalculator }

    switch firstWord {
    case "solve":                       return .solve
    case "graph", "plot":               return .graph
    case "differentiate", "derivative": return .differentiate
    case "integrate", "integral":       return .integrate
    case "units":                       return .units
    case "balance":                     return .balance
    case "transcribe":                  return .transcribe
    case "translate":                   return .translate
    case "punnett", "cross":            return .punnett
    case "animate":                     return .animate(rest)
    case "quiz":                        return .quiz(quizTopic(s))
    case "check", "redpen":             return .checkWork
    case "make", "build", "create", "draw", "generate":
        return .makeReal(rest.isEmpty ? s : rest)
    case "why", "what", "how", "when", "who", "explain", "is", "does", "can":
        return .explain(s)
    default:
        return lower.hasSuffix("?") ? .explain(s) : .makeReal(s)
    }
}

private func restAfterFirstWord(_ s: String) -> String {
    let parts = s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    return parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
}

private func quizTopic(_ s: String) -> String {
    // "quiz me on Biology" → "Biology"
    var t = restAfterFirstWord(s)               // "me on Biology"
    for prefix in ["me on ", "me about ", "on ", "about "] {
        if t.lowercased().hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)); break }
    }
    return t.trimmingCharacters(in: .whitespaces)
}

// MARK: - Intent → dispatch (§4.3)

public func dispatch(for intent: Intent) -> Dispatch {
    switch intent {
    case .solve:                 return .deterministic(engine: "InkLabMath", action: "solve")
    case .graph:                 return .deterministic(engine: "InkLabMath", action: "graph")
    case .checkWork:             return .deterministic(engine: "InkLabMath", action: "redPen")
    case .differentiate:         return .deterministic(engine: "InkLabMath", action: "differentiate")
    case .integrate:             return .deterministic(engine: "InkLabMath", action: "integrate")
    case .units:                 return .deterministic(engine: "InkLabUnits", action: "check")
    case .balance:               return .deterministic(engine: "InkLabChem", action: "balance")
    case .molarMass:             return .deterministic(engine: "InkLabChem", action: "molarMass")
    case .transcribe:            return .deterministic(engine: "InkLabBio", action: "transcribe")
    case .translate:             return .deterministic(engine: "InkLabBio", action: "translate")
    case .punnett:               return .deterministic(engine: "InkLabBio", action: "punnett")
    case .scientificCalculator:  return .native(widget: "scientificCalculator")
    case .makeReal(let p):       return .generative(prompt: p)
    case .animate(let s):        return .generative(prompt: "animate: \(s)")
    case .explain(let q):        return .generative(prompt: "explain: \(q)")
    case .quiz(let t):           return .generative(prompt: "quiz on: \(t)")
    case .unknown(let s):        return .generative(prompt: s)
    }
}

// MARK: - Action chips for a recognized selection (§5.1)

/// The AI action chips offered for a recognized selection, by its formal structure + domain.
public func actionChips(for formal: FormalStructure, domain: DomainFamily) -> [Intent] {
    switch formal {
    case .latex, .mathML, .expressionTree:
        return [.solve, .graph, .checkWork, .differentiate, .integrate, .units]
    case .smiles:
        return [.molarMass]
    case .netlist:
        return [.makeReal("simulate this circuit")]
    case .plainText, .unrecognized:
        return []
    }
}
