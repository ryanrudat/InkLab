import Foundation
import InkLabKit

/// In-memory wrapper around the InkLabDoc journal: an op log + the folded projection, with undo/redo.
/// (The GRDB local store + CKSyncEngine transport replace this in the on-device phase, ADR 0004.)
final class JournalStore {
    let notebookID = UUID()
    let pageID = UUID()
    private(set) var projection: NotebookProjection
    private var log: [Op] = []
    private let clock = Clock(startWall: 1)
    private var undoStack: [UUID] = []
    private var redoStack: [[OpPayload]] = []
    private var payloadsByTxn: [UUID: [OpPayload]] = [:]

    init() {
        projection = NotebookProjection(id: notebookID)
        apply([op(.addPage(meta: PageMeta(pageID: pageID, index: 0, extentY: 0)))], txn: nil)
    }

    var page: PageProjection { projection.pages[pageID] ?? PageProjection(id: pageID) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private func op(_ payload: OpPayload, txn: UUID? = nil) -> Op {
        Op(id: clock.nextOpID(), hlc: clock.tick(), notebookID: notebookID, transactionID: txn, payload: payload)
    }

    /// Apply a user action as ONE undo transaction.
    func perform(_ payloads: [OpPayload], clearRedo: Bool = true) {
        let txn = UUID()
        apply(payloads.map { op($0, txn: txn) }, txn: txn)
        payloadsByTxn[txn] = payloads
        if clearRedo { redoStack.removeAll() }
    }

    func undo() {
        guard let txn = undoStack.popLast() else { return }
        let inverse = undoTransaction(txn, in: log, using: clock)
        log.append(contentsOf: inverse)
        projection = fold(log, notebookID: notebookID)
        if let payloads = payloadsByTxn[txn] { redoStack.append(payloads) }
    }

    func redo() {
        guard let payloads = redoStack.popLast() else { return }
        perform(payloads, clearRedo: false)
    }

    private func apply(_ ops: [Op], txn: UUID?) {
        log.append(contentsOf: ops)
        projection = fold(log, notebookID: notebookID)
        if let txn { undoStack.append(txn) }
    }
}
