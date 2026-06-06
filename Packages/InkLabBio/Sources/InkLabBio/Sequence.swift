import Foundation

private let dnaBases: Set<Character> = ["A", "C", "G", "T"]
private let rnaBases: Set<Character> = ["A", "C", "G", "U"]

/// Transcribe a coding (sense) DNA strand to mRNA (T → U). Returns nil on a non-DNA base.
public func transcribe(coding dna: String) -> String? {
    let s = dna.uppercased()
    guard s.allSatisfy(dnaBases.contains) else { return nil }
    return String(s.map { $0 == "T" ? "U" : $0 })
}

/// DNA complement (A↔T, C↔G). Returns nil on a non-DNA base.
public func complementDNA(_ dna: String) -> String? {
    let map: [Character: Character] = ["A": "T", "T": "A", "C": "G", "G": "C"]
    let s = dna.uppercased()
    var out = ""
    for c in s { guard let m = map[c] else { return nil }; out.append(m) }
    return out
}

/// Reverse complement of a DNA strand (5'→3' of the opposite strand).
public func reverseComplementDNA(_ dna: String) -> String? {
    complementDNA(dna).map { String($0.reversed()) }
}

public struct Translation: Equatable, Sendable {
    public let peptide: String     // 1-letter amino acids, up to (not including) a stop codon
    public let reachedStop: Bool
}

/// Translate mRNA to a peptide using the standard code. If `fromFirstAUG`, scanning starts at the
/// first start codon (returns an empty peptide if none). Stops at the first stop codon. Returns nil
/// on a non-RNA base or an incomplete leading codon table entry.
public func translate(_ mRNA: String, fromFirstAUG: Bool = false) -> Translation? {
    let s = Array(mRNA.uppercased())
    guard s.allSatisfy(rnaBases.contains) else { return nil }
    var i = 0
    if fromFirstAUG {
        var found = -1
        var k = 0
        while k + 3 <= s.count { if String(s[k..<k+3]) == "AUG" { found = k; break }; k += 1 }
        if found < 0 { return Translation(peptide: "", reachedStop: false) }
        i = found
    }
    var peptide = ""
    var reachedStop = false
    while i + 3 <= s.count {
        guard let aa = CodonTable.code[String(s[i..<i+3])] else { return nil }
        if aa == "*" { reachedStop = true; break }
        peptide.append(aa)
        i += 3
    }
    return Translation(peptide: peptide, reachedStop: reachedStop)
}

/// Convenience: transcribe a coding DNA strand and translate it.
public func translateDNA(coding dna: String, fromFirstAUG: Bool = false) -> Translation? {
    guard let mRNA = transcribe(coding: dna) else { return nil }
    return translate(mRNA, fromFirstAUG: fromFirstAUG)
}

// MARK: - Point mutations

public enum MutationEffect: Equatable, Sendable {
    case silent
    case missense(from: Character, to: Character)
    case nonsense                      // a sense codon becomes a stop codon
    case stopLost                      // a stop codon becomes a sense codon
    case invalid
}

/// Classify a single-codon substitution at the mRNA level (codons are RNA, 3 bases each).
public func classifyCodonSubstitution(_ original: String, _ mutated: String) -> MutationEffect {
    guard let a = CodonTable.code[original.uppercased()], let b = CodonTable.code[mutated.uppercased()] else { return .invalid }
    if a == b { return .silent }
    if b == "*" { return .nonsense }
    if a == "*" { return .stopLost }
    return .missense(from: a, to: b)
}

/// Classify a single-base substitution at `position` (0-based) on an mRNA: locate the affected
/// codon, apply the change, and compare amino acids.
public func pointMutationEffect(mRNA: String, position: Int, newBase: Character) -> MutationEffect {
    var s = Array(mRNA.uppercased())
    let nb = Character(String(newBase).uppercased())
    guard position >= 0, position < s.count, rnaBases.contains(nb) else { return .invalid }
    let start = (position / 3) * 3
    guard start + 3 <= s.count else { return .invalid }
    let original = String(s[start..<start+3])
    s[position] = nb
    let mutated = String(s[start..<start+3])
    return classifyCodonSubstitution(original, mutated)
}
