import Foundation

/// The result of a genetic cross: genotype and phenotype counts (out of `total`).
public struct Cross: Equatable, Sendable {
    public let genotypes: [String: Int]
    public let phenotypes: [String: Int]
    public let total: Int
}

/// The gametes produced by a genotype (one allele per gene), keeping duplicates so ratios are
/// correct (e.g. "AA" -> ["A","A"]). "AaBb" -> ["AB","Ab","aB","ab"]. nil if malformed (each gene
/// must be two alleles of the SAME letter, like Aa / AA / aa).
public func gametes(_ genotype: String) -> [String]? {
    let cs = Array(genotype)
    guard !cs.isEmpty, cs.count % 2 == 0, cs.allSatisfy(\.isLetter) else { return nil }
    var genes: [[Character]] = []
    var k = 0
    while k < cs.count {
        let a = cs[k], b = cs[k + 1]
        guard a.lowercased() == b.lowercased() else { return nil }   // both alleles of one gene
        genes.append([a, b]); k += 2
    }
    var result = [""]
    for gene in genes {
        var next: [String] = []
        for prefix in result { for allele in gene { next.append(prefix + String(allele)) } }
        result = next
    }
    return result
}

/// Order a gene's two alleles canonically (dominant/uppercase first), e.g. ("a","A") -> "Aa".
private func canonicalPair(_ a: Character, _ b: Character) -> String {
    let sorted = [a, b].sorted { x, y in x.isUppercase != y.isUppercase ? x.isUppercase : x < y }
    return String(sorted)
}

/// Compute a Punnett cross. Genotypes are reported with alleles ordered dominant-first; phenotypes
/// use the gene letter (uppercase = dominant phenotype present, lowercase = recessive). Monohybrid
/// "Aa"×"Aa" → genotypes AA:1, Aa:2, aa:1; dihybrid "AaBb"×"AaBb" → phenotypes 9:3:3:1.
public func punnett(_ p1: String, _ p2: String) -> Cross? {
    guard p1.count == p2.count, let g1 = gametes(p1), let g2 = gametes(p2),
          let first = g1.first else { return nil }
    let nGenes = first.count
    var genotypes: [String: Int] = [:]
    var phenotypes: [String: Int] = [:]
    for a in g1 {
        let aa = Array(a)
        for b in g2 {
            let bb = Array(b)
            var genotype = "", phenotype = ""
            for i in 0..<nGenes {
                let pair = canonicalPair(aa[i], bb[i])
                genotype += pair
                let dominant = pair.contains(where: \.isUppercase)
                let letter = Character(pair.prefix(1).uppercased())
                phenotype.append(dominant ? letter : Character(String(letter).lowercased()))
            }
            genotypes[genotype, default: 0] += 1
            phenotypes[phenotype, default: 0] += 1
        }
    }
    return Cross(genotypes: genotypes, phenotypes: phenotypes, total: g1.count * g2.count)
}
