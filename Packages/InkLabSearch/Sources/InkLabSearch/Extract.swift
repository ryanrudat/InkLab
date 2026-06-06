import Foundation
import InkLabDoc

/// Pull searchable text out of a notebook's projection: sticky-note text, the "read as" transcription
/// of recognized objects, and AI callout text. (Ink that hasn't been recognized has no text yet — it
/// becomes searchable once recognized, per brief §7.)
public func searchableText(_ payload: ObjectPayload) -> String? {
    switch payload {
    case .sticky(let text, _): return text
    case .recognized(let body): return body.readAs
    case .callout(let text, _, _): return text
    default: return nil
    }
}

/// Build search documents for every non-deleted, text-bearing object in a notebook projection.
public func searchDocuments(from projection: NotebookProjection) -> [SearchDoc] {
    var out: [SearchDoc] = []
    for (pageID, page) in projection.pages {
        for (objectID, obj) in page.objects where !obj.isDeleted {
            guard let text = searchableText(obj.payload), !text.isEmpty else { continue }
            out.append(SearchDoc(notebookID: projection.id, pageID: pageID, objectID: objectID,
                                 kind: obj.kind.rawValue, text: text))
        }
    }
    return out
}
