import Foundation

/// One searchable item — a reference back to an object plus its text. (Pure value type; the
/// extractor in Extract.swift builds these from the journal.)
public struct SearchDoc: Equatable, Sendable, Hashable {
    public var notebookID: UUID
    public var pageID: UUID
    public var objectID: UUID
    public var kind: String
    public var text: String
    public init(notebookID: UUID, pageID: UUID, objectID: UUID, kind: String, text: String) {
        self.notebookID = notebookID; self.pageID = pageID; self.objectID = objectID
        self.kind = kind; self.text = text
    }
}

public struct SearchHit: Equatable, Sendable {
    public var doc: SearchDoc
    public var score: Double
    public var snippet: String
}

func tokenize(_ s: String) -> [String] {
    s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty }
}

/// An in-memory inverted index over `SearchDoc`s. Supports prefix matching (good for incremental
/// search-as-you-type) and AND queries (every query term must match), ranked by term frequency with
/// a small boost for recognized content.
public final class SearchIndex {
    private var docs: [SearchDoc] = []
    private var postings: [String: [Int: Int]] = [:]   // token → (docIndex → term frequency)

    public init() {}

    public func clear() { docs.removeAll(); postings.removeAll() }

    public func add(_ doc: SearchDoc) {
        let idx = docs.count
        docs.append(doc)
        for token in tokenize(doc.text) {
            postings[token, default: [:]][idx, default: 0] += 1
        }
    }

    public func index(_ newDocs: [SearchDoc]) { for d in newDocs { add(d) } }

    public var count: Int { docs.count }

    public func search(_ query: String, limit: Int = 20) -> [SearchHit] {
        let qTokens = tokenize(query)
        guard !qTokens.isEmpty else { return [] }

        // For each query token, accumulate matching docs (exact or prefix) → term frequency.
        var perToken: [[Int: Int]] = []
        for q in qTokens {
            var acc: [Int: Int] = [:]
            for (token, posting) in postings where token == q || token.hasPrefix(q) {
                for (docIdx, tf) in posting { acc[docIdx, default: 0] += tf }
            }
            perToken.append(acc)
        }

        // AND semantics: a doc must satisfy every query token.
        guard var common = perToken.first.map({ Set($0.keys) }) else { return [] }
        for m in perToken.dropFirst() { common.formIntersection(m.keys) }

        var hits: [SearchHit] = []
        for docIdx in common {
            let tf = perToken.reduce(0.0) { $0 + Double($1[docIdx] ?? 0) }
            let doc = docs[docIdx]
            let score = tf * kindWeight(doc.kind)
            hits.append(SearchHit(doc: doc, score: score, snippet: snippet(doc.text, qTokens)))
        }
        return hits
            .sorted { ($0.score, $1.doc.text) > ($1.score, $0.doc.text) }   // score desc, stable tiebreak
            .prefix(limit)
            .map { $0 }
    }

    private func kindWeight(_ kind: String) -> Double { kind == "recognized" ? 1.5 : 1.0 }

    private func snippet(_ text: String, _ qTokens: [String]) -> String {
        let lower = text.lowercased()
        for q in qTokens {
            if let r = lower.range(of: q) {
                let start = text.index(r.lowerBound, offsetBy: -20, limitedBy: text.startIndex) ?? text.startIndex
                let end = text.index(r.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
                let prefix = start > text.startIndex ? "…" : ""
                let suffix = end < text.endIndex ? "…" : ""
                return prefix + text[start..<end] + suffix
            }
        }
        return String(text.prefix(60))
    }
}
