import Foundation
import InkLabKit
import os

/// Wrapper around the InkLabDoc journal: an op log + the folded projection, with **multi-page
/// navigation and PER-PAGE undo/redo** (back/forward is scoped to the page you're on) and **durable
/// persistence** via a swappable `JournalStorage` (ADR 0004; file-backed today, GRDB-ready). Object ops
/// persist here; ink blobs persist alongside (the canvas writes them through the same storage).
final class JournalStore {
    let notebookID: UUID
    private let storage: JournalStorage
    private(set) var pageIDs: [UUID]
    private(set) var currentPageID: UUID
    private(set) var projection: NotebookProjection
    private var log: [Op] = []
    private let clock = Clock(startWall: 1)
    // Per-page undo/redo: each page keeps its own transaction stacks (NOT persisted — undo resets on launch).
    private var undoStacks: [UUID: [UUID]] = [:]
    private var redoStacks: [UUID: [[OpPayload]]] = [:]
    private var payloadsByTxn: [UUID: [OpPayload]] = [:]
    private let logger = Logger(subsystem: "com.ryanrudat.InkLab", category: "JournalStore")

    /// Called when an op can't be persisted to disk (disk full / I/O error). The op stays in the live
    /// session (so the user doesn't see their work vanish mid-edit), but it WON'T survive relaunch — the
    /// UI should warn. Defaults to nil (logged only). Wire to a status banner.
    var onPersistenceError: ((Error) -> Void)?

    /// UserDefaults key for the last page the user viewed in THIS notebook (UI state, not document data).
    private var currentPageKey: String { "inklab.currentPage.\(notebookID.uuidString)" }

    init(notebookID: UUID = UUID(), storage: JournalStorage = EphemeralJournalStorage()) {
        self.notebookID = notebookID
        self.storage = storage
        self.projection = NotebookProjection(id: notebookID)
        self.pageIDs = []
        self.currentPageID = UUID()   // replaced below
        let loaded = storage.loadOps()
        if loaded.isEmpty {
            // Fresh notebook — create and persist page 1.
            let first = UUID()
            currentPageID = first
            apply([op(.addPage(meta: PageMeta(pageID: first, index: 0, extentY: 0)))], txn: nil, page: nil)
            pageIDs = [first]
        } else {
            // Reload: replay the persisted op log. `fold` orders by HLC (not append order), so advance
            // the clock past the loaded ops — new edits must sort AFTER everything already on disk.
            log = loaded
            clock.advance(toWall: (loaded.map { $0.hlc.wallMillis }.max() ?? 0) + 1)
            projection = fold(log, notebookID: notebookID)
            pageIDs = projection.pageOrder.isEmpty ? Array(projection.pages.keys) : projection.pageOrder
            // Reopen on the page the user last viewed — NOT always page 1 — so work on later pages isn't
            // perceived as "lost" on relaunch. Falls back to the first page if the pref is missing/stale.
            if let saved = UserDefaults.standard.string(forKey: currentPageKey),
               let id = UUID(uuidString: saved), pageIDs.contains(id) {
                currentPageID = id
            } else {
                currentPageID = pageIDs.first ?? currentPageID
            }
        }
    }

    /// The current page id. (Kept named `pageID` so existing call sites that tag new objects keep working.)
    var pageID: UUID { currentPageID }
    var page: PageProjection { projection.pages[currentPageID] ?? PageProjection(id: currentPageID) }
    func pageProjection(_ id: UUID) -> PageProjection { projection.pages[id] ?? PageProjection(id: id) }
    var pageCount: Int { pageIDs.count }
    var currentPageIndex: Int { pageIDs.firstIndex(of: currentPageID) ?? 0 }
    var canUndo: Bool { !(undoStacks[currentPageID]?.isEmpty ?? true) }
    var canRedo: Bool { !(redoStacks[currentPageID]?.isEmpty ?? true) }

    /// Append a new blank page at the end and return its id (does not change the current page).
    @discardableResult
    func addPage() -> UUID {
        let id = UUID()
        apply([op(.addPage(meta: PageMeta(pageID: id, index: pageIDs.count, extentY: 0)))], txn: nil, page: nil)
        pageIDs.append(id)
        return id
    }

    /// Switch the current page (no-op for an unknown id). Remembers it so relaunch reopens here.
    func goTo(_ id: UUID) {
        guard pageIDs.contains(id) else { return }
        currentPageID = id
        UserDefaults.standard.set(id.uuidString, forKey: currentPageKey)
    }

    private func op(_ payload: OpPayload, txn: UUID? = nil) -> Op {
        Op(id: clock.nextOpID(), hlc: clock.tick(), notebookID: notebookID, transactionID: txn, payload: payload)
    }

    /// Apply a user action as ONE undo transaction on a page (defaults to the current page).
    func perform(_ payloads: [OpPayload], onPage page: UUID? = nil, clearRedo: Bool = true) {
        let pid = page ?? currentPageID
        let txn = UUID()
        apply(payloads.map { op($0, txn: txn) }, txn: txn, page: pid)
        payloadsByTxn[txn] = payloads
        if clearRedo { redoStacks[pid]?.removeAll() }
    }

    func undo() {
        guard let txn = undoStacks[currentPageID]?.popLast() else { return }
        let inverse = undoTransaction(txn, in: log, using: clock)
        log.append(contentsOf: inverse)
        persist(inverse)   // persist the inverse ops too, so the undo survives relaunch
        projection = fold(log, notebookID: notebookID)
        if let payloads = payloadsByTxn[txn] { redoStacks[currentPageID, default: []].append(payloads) }
    }

    func redo() {
        guard let payloads = redoStacks[currentPageID]?.popLast() else { return }
        perform(payloads, onPage: currentPageID, clearRedo: false)
    }

    private func apply(_ ops: [Op], txn: UUID?, page: UUID?) {
        log.append(contentsOf: ops)
        persist(ops)          // durable: every op is persisted as it happens (failures surfaced, not swallowed)
        projection = fold(log, notebookID: notebookID)
        if let txn, let page { undoStacks[page, default: []].append(txn) }
    }

    /// Persist ops, surfacing any failure (the in-memory state already reflects them — we warn rather
    /// than roll back, so the user doesn't see their just-made edit vanish; but they're told it isn't saved).
    private func persist(_ ops: [Op]) {
        do {
            try storage.append(ops)
        } catch {
            logger.error("op-log persist failed: \(error.localizedDescription, privacy: .public)")
            onPersistenceError?(error)
        }
    }
}
