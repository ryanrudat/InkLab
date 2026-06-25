import Foundation
import InkLabKit
import os

/// Durable storage for a notebook's journal (ADR 0004). Two halves: the event-sourced **op log**
/// (every user action, replayed on launch by `fold`) and **ink blobs** (one PKDrawing per page,
/// passed as `Data` so this layer stays PencilKit-free). Swappable — the file impl below ships now;
/// a GRDB/SQLite impl can drop in behind this same protocol later (and CloudKit sync on top).
protocol JournalStorage {
    func loadOps() -> [Op]
    /// Throws on a real persistence failure (disk full, I/O error, pre-first-unlock denial) so the
    /// caller can SURFACE it rather than silently losing the op. (Previously this swallowed all errors,
    /// so an op the live session showed as applied could simply be missing after relaunch.)
    func append(_ ops: [Op]) throws
    func loadInk(page: UUID) -> Data?
    func saveInk(_ data: Data, page: UUID)
}

/// No-op storage: nothing survives the process. The default for transient notebooks and unit tests
/// (so they don't touch disk).
struct EphemeralJournalStorage: JournalStorage {
    func loadOps() -> [Op] { [] }
    func append(_ ops: [Op]) throws {}
    func loadInk(page: UUID) -> Data? { nil }
    func saveInk(_ data: Data, page: UUID) {}
}

/// File-backed store, scoped to one notebook (keyed by `notebookID`), under Application Support:
///   …/InkLab/notebooks/<id>/oplog.jsonl   — append-only, one JSON-encoded `Op` per line
///   …/InkLab/notebooks/<id>/ink/<page>.drawing — one PKDrawing-data blob per page
/// Append is O(1); reload reads the whole log once and `fold` replays it. Survives relaunch.
final class FileJournalStorage: JournalStorage {
    private let opLogURL: URL
    private let inkDir: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let log = Logger(subsystem: "com.ryanrudat.InkLab", category: "JournalStorage")

    /// `root` overridable for tests; defaults to Application Support.
    init(notebookID: UUID, root: URL? = nil) {
        let dir = Self.notebookDir(notebookID, root: root)
        opLogURL = dir.appendingPathComponent("oplog.jsonl")
        inkDir = dir.appendingPathComponent("ink", isDirectory: true)
        do {
            // `completeUntilFirstUserAuthentication`: background flushes still write while the device is
            // locked (after first unlock) — otherwise locked-device saves throw and silently lose data.
            try FileManager.default.createDirectory(at: inkDir, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        } catch {
            log.error("createDirectory failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func notebookDir(_ notebookID: UUID, root: URL? = nil) -> URL {
        let base = root ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                            ?? FileManager.default.temporaryDirectory)
        return base.appendingPathComponent("InkLab/notebooks/\(notebookID.uuidString)", isDirectory: true)
    }

    /// Remove a deleted notebook's on-disk journal + ink (called from `Library.delete`).
    static func deleteStore(notebookID: UUID, root: URL? = nil) {
        try? FileManager.default.removeItem(at: notebookDir(notebookID, root: root))
    }

    func loadOps() -> [Op] {
        guard let data = try? Data(contentsOf: opLogURL), !data.isEmpty else { return [] }
        // IMPORTANT: keep the encoder COMPACT — compact JSON escapes newlines (\n), so one op == one
        // line. (Enabling .prettyPrinted would emit literal newlines and break this splitting.)
        let lines = data.split(separator: 0x0A)
        var ops: [Op] = []
        var interiorFailures = 0, tornTail = false
        for (idx, line) in lines.enumerated() {
            if let op = try? decoder.decode(Op.self, from: Data(line)) {
                ops.append(op)
            } else if idx == lines.count - 1 {
                tornTail = true            // expected: a kill mid-append can only tear the LAST line
            } else {
                interiorFailures += 1      // unexpected: mid-file corruption or a forward-incompatible op
            }
        }
        if tornTail {
            log.info("op-log: ignored a torn final line (kill mid-write) — expected, safe")
        }
        if interiorFailures > 0 {
            // The append path only ever GROWS the file (seekToEnd), so an interior line can never be a
            // torn tail — this is real on-disk corruption or a forward-incompatible op from a newer
            // client. Surface it loudly (previously it was silently lumped in with the benign torn tail).
            // Replay continues with the readable ops: a later op referencing a dropped one degrades to a
            // no-op rather than crashing. TODO (ADR 0004): a proper quarantine + raster-fallback recovery.
            log.error("op-log: \(interiorFailures) INTERIOR unreadable op(s) of \(lines.count) — possible corruption; replay may be incomplete")
        }
        return ops
    }

    func append(_ ops: [Op]) throws {
        guard !ops.isEmpty else { return }
        var blob = Data()
        for op in ops {
            blob.append(try encoder.encode(op))   // an un-encodable op is a real failure — throw, don't drop
            blob.append(0x0A)
        }
        guard !blob.isEmpty else { return }
        do {
            if let handle = try? FileHandle(forWritingTo: opLogURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()           // always true EOF — the file only grows, never corrupts earlier ops
                try handle.write(contentsOf: blob)
                try? handle.synchronize()        // fsync: shrink the torn-tail window on a crash mid-write
            } else {
                try blob.write(to: opLogURL, options: .atomic)   // first write — create it
            }
        } catch {
            log.error("op-log append failed: \(error.localizedDescription, privacy: .public)")
            throw error   // propagate so JournalStore can surface "not saved" instead of silent loss
        }
    }

    func loadInk(page: UUID) -> Data? { try? Data(contentsOf: inkURL(page)) }
    func saveInk(_ data: Data, page: UUID) {
        do { try data.write(to: inkURL(page), options: .atomic) }
        catch { log.error("ink save failed: \(error.localizedDescription, privacy: .public)") }
    }
    private func inkURL(_ page: UUID) -> URL { inkDir.appendingPathComponent("\(page.uuidString).drawing") }
}
