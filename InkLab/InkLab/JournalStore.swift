import Foundation
import InkLabKit

/// In-memory wrapper around the InkLabDoc journal for the app slice: an op log + the folded
/// projection, with each user action recorded as one undo transaction. The GRDB local store +
/// CKSyncEngine transport (ADR 0004) replace this in-memory log in the on-device phase.
final class JournalStore {
    let notebookID = UUID()
    let pageID = UUID()
    private(set) var projection: NotebookProjection
    private var log: [Op] = []
    private let clock = Clock(startWall: 1)
    private var undoableTransactions: [UUID] = []

    init() {
        projection = NotebookProjection(id: notebookID)
        apply([op(.addPage(meta: PageMeta(pageID: pageID, index: 0, extentY: 0)))], undoableTxn: nil)
    }

    var page: PageProjection { projection.pages[pageID] ?? PageProjection(id: pageID) }
    var canUndo: Bool { !undoableTransactions.isEmpty }

    func op(_ payload: OpPayload, txn: UUID? = nil) -> Op {
        Op(id: clock.nextOpID(), hlc: clock.tick(), notebookID: notebookID, transactionID: txn, payload: payload)
    }

    /// Apply a user action as ONE undo transaction.
    func perform(_ payloads: [OpPayload]) {
        let txn = UUID()
        apply(payloads.map { op($0, txn: txn) }, undoableTxn: txn)
    }

    func undo() {
        guard let txn = undoableTransactions.popLast() else { return }
        let inverse = undoTransaction(txn, in: log, using: clock)
        log.append(contentsOf: inverse)
        projection = fold(log, notebookID: notebookID)
    }

    private func apply(_ ops: [Op], undoableTxn: UUID?) {
        log.append(contentsOf: ops)
        projection = fold(log, notebookID: notebookID)
        if let txn = undoableTxn { undoableTransactions.append(txn) }
    }
}
