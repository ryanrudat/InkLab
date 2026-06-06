import Foundation

/// The deterministic gate that decides whether a recognizer's output is good enough to accept.
/// This is what makes "correct or silent" real: cloud (and low-confidence on-device) output is
/// NEVER handed to the compute engine unless it parses into something the engine accepts.
///
/// The shipping implementation should run the REAL deterministic parser:
///   - math:      LaTeX/MathML/JIIX must compile into a valid `MathNode` tree
///   - chemistry: SMILES must pass an RDKit valence/parse check
///   - diagram:   netlist must reference consistent nodes
/// `DefaultFormalStructureValidator` is a non-empty/structural placeholder so the routing logic is
/// testable today; replace it once the engine packages exist.
public protocol FormalStructureValidator: Sendable {
    func validate(_ formal: FormalStructure, family: DomainFamily) -> Bool
}

public struct DefaultFormalStructureValidator: FormalStructureValidator {
    public init() {}

    public func validate(_ formal: FormalStructure, family: DomainFamily) -> Bool {
        switch formal {
        case .unrecognized:
            return false
        case .latex(let s), .mathML(let s):
            return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .plainText(let s):
            return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .smiles(let s):
            return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .expressionTree:
            return true
        case .netlist(let n):
            return !n.components.isEmpty
        }
    }
}
