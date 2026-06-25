import XCTest
@testable import InkLabSearch
import InkLabDoc
import InkLabRecognition

final class SearchTests: XCTestCase {

    func doc(_ kind: String, _ text: String) -> SearchDoc {
        SearchDoc(notebookID: UUID(), pageID: UUID(), objectID: UUID(), kind: kind, text: text)
    }

    func test_findsMatchingDocuments() {
        let idx = SearchIndex()
        idx.index([doc("sticky", "Photosynthesis converts light to chemical energy"),
                   doc("sticky", "Cellular respiration releases energy"),
                   doc("recognized", "f(x) = x^2 + 3x")])
        let hits = idx.search("energy")
        XCTAssertEqual(hits.count, 2)
        XCTAssertTrue(hits.allSatisfy { $0.doc.text.lowercased().contains("energy") })
    }

    /// Regression: snippet generation used to mix indices from text.lowercased() into the original
    /// text and crash when lowercasing changed length (Turkish "İ" → "i"+combining dot). The search +
    /// snippet must complete without trapping and return a hit.
    func test_snippetDoesNotCrashOnNonASCII() {
        let idx = SearchIndex()
        let leading = String(repeating: "İ ", count: 15)   // length-expanding-on-lowercase prefix
        idx.add(doc("sticky", leading + "energy stored here"))
        let hits = idx.search("energy")
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].snippet.lowercased().contains("energy"))
    }

    func test_prefixMatching() {
        let idx = SearchIndex()
        idx.add(doc("sticky", "Photosynthesis"))
        XCTAssertEqual(idx.search("photo").count, 1)   // search-as-you-type
        XCTAssertEqual(idx.search("synth").count, 0)   // prefix is from the start of a token
    }

    func test_andQueryRequiresAllTerms() {
        let idx = SearchIndex()
        idx.add(doc("sticky", "light energy"))
        idx.add(doc("sticky", "chemical energy"))
        XCTAssertEqual(idx.search("light energy").count, 1)   // only the first has both
        XCTAssertEqual(idx.search("energy").count, 2)
    }

    func test_recognizedContentRanksAbove() {
        let idx = SearchIndex()
        idx.add(doc("sticky", "derivative notes"))
        idx.add(doc("recognized", "derivative"))
        let hits = idx.search("derivative")
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.first?.doc.kind, "recognized")   // boosted
    }

    func test_emptyAndNoMatch() {
        let idx = SearchIndex()
        idx.add(doc("sticky", "hello"))
        XCTAssertTrue(idx.search("").isEmpty)
        XCTAssertTrue(idx.search("zzz").isEmpty)
    }

    func test_extractsFromJournalProjection() {
        // Build a one-page notebook projection with a sticky + a recognized object, then search it.
        let nb = UUID(), page = UUID(), author = UUID()
        let sticky = ObjectSnapshot(objectID: UUID(), kind: .sticky, pageID: page, createdBy: author,
                                    payload: .sticky(text: "mitosis stages", colorHex: "#fff"))
        let recog = ObjectSnapshot(objectID: UUID(), kind: .recognized, pageID: page, createdBy: author,
                                   payload: .recognized(RecognizedBody(formal: .latex("x^2"), readAs: "x squared", confidence: 0.9)))
        let projection = NotebookProjection(id: nb, pageOrder: [page],
            pages: [page: PageProjection(id: page, objects: [sticky.objectID: sticky, recog.objectID: recog])])

        let idx = SearchIndex()
        idx.index(searchDocuments(from: projection))
        XCTAssertEqual(idx.count, 2)
        XCTAssertEqual(idx.search("mitosis").first?.doc.objectID, sticky.objectID)
        XCTAssertEqual(idx.search("squared").first?.doc.objectID, recog.objectID)
    }
}
