import XCTest
@testable import InkLabBio

final class BioTests: XCTestCase {

    // MARK: - Sequence operations

    func test_transcribeAndComplement() {
        XCTAssertEqual(transcribe(coding: "ATGGCC"), "AUGGCC")
        XCTAssertEqual(complementDNA("ATGC"), "TACG")
        XCTAssertEqual(reverseComplementDNA("ATGC"), "GCAT")
        XCTAssertNil(transcribe(coding: "ATGX"))    // invalid base
    }

    func test_translation() {
        // ATG GCC TAA -> Met, Ala, stop
        XCTAssertEqual(translateDNA(coding: "ATGGCCTAA"), Translation(peptide: "MA", reachedStop: true))
        XCTAssertEqual(translate("AUGUUUUAA"), Translation(peptide: "MF", reachedStop: true))
        XCTAssertNil(translate("AUGTTT"))           // T isn't an RNA base
    }

    func test_translationFromFirstAUG() {
        // leading junk, then AUG GCA UAA
        XCTAssertEqual(translate("CCAUGGCAUAA", fromFirstAUG: true), Translation(peptide: "MA", reachedStop: true))
    }

    // MARK: - Mutation classification

    func test_pointMutationClassification() {
        XCTAssertEqual(classifyCodonSubstitution("UUU", "UUC"), .silent)            // F -> F
        XCTAssertEqual(classifyCodonSubstitution("UUU", "CUU"), .missense(from: "F", to: "L"))
        XCTAssertEqual(classifyCodonSubstitution("UAC", "UAA"), .nonsense)          // Y -> stop
        XCTAssertEqual(classifyCodonSubstitution("UAA", "CAA"), .stopLost)          // stop -> Q
    }

    func test_pointMutationOnSequence() {
        // mRNA AUG UUU UAU ; mutate position 5 (the 3rd base of codon 2, UUU) U->C => UUC, still Phe
        XCTAssertEqual(pointMutationEffect(mRNA: "AUGUUUUAU", position: 5, newBase: "C"), .silent)
        // mutate position 3 (1st base of codon 2) U->? keep within table; U->A gives AUU = Ile (missense F->I)
        XCTAssertEqual(pointMutationEffect(mRNA: "AUGUUUUAU", position: 3, newBase: "A"), .missense(from: "F", to: "I"))
    }

    // MARK: - Genetics / Punnett

    func test_gametes() {
        XCTAssertEqual(gametes("Aa"), ["A", "a"])
        XCTAssertEqual(gametes("AaBb"), ["AB", "Ab", "aB", "ab"])
        XCTAssertEqual(gametes("AA"), ["A", "A"])      // duplicates kept for correct ratios
        XCTAssertNil(gametes("Ab"))                    // two different gene letters in one pair
    }

    func test_monohybridCross() {
        let c = punnett("Aa", "Aa")!
        XCTAssertEqual(c.genotypes, ["AA": 1, "Aa": 2, "aa": 1])
        XCTAssertEqual(c.phenotypes, ["A": 3, "a": 1])      // 3:1 dominant:recessive
        XCTAssertEqual(c.total, 4)
    }

    func test_dihybridCross_gives_9_3_3_1() {
        let c = punnett("AaBb", "AaBb")!
        XCTAssertEqual(c.phenotypes, ["AB": 9, "Ab": 3, "aB": 3, "ab": 1])
        XCTAssertEqual(c.total, 16)
    }
}
