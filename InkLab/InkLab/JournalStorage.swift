import Foundation
import InkLabKit
import os

/// Durable storage for a notebook's journal (ADR 0004). Two halves: the event-sourced **op log**
/// (every user action, replayed on launch by `fold`) and **ink blobs** (one PKDrawing per page,
/// passed as `Data` so this layer stays PencilKit-free). Swappable — the file impl below ships now;
/// a GRDB/SQLite impl can drop in behind this same protocol later (and CloudKit sync on top).
enum JournalStorageError: LocalizedError, Equatable {
    case corruptOpLog(unreadableLines: Int, totalLines: Int)

    var errorDescription: String? {
        switch self {
        case .corruptOpLog(let unreadable, let total):
            return "The notebook journal is damaged (\(unreadable) unreadable entr\(unreadable == 1 ? "y" : "ies") out of \(total))."
        }
    }
}

protocol JournalStorage {
    /// A missing log is a new notebook (`[]`). Any other read/corruption failure throws so callers never
    /// mistake an unreadable notebook for an empty one and seed new data over it.
    func loadOps() throws -> [Op]
    /// Throws on a real persistence failure (disk full, I/O error, pre-first-unlock denial) so the
    /// caller can SURFACE it rather than silently losing the op. (Previously this swallowed all errors,
    /// so an op the live session showed as applied could simply be missing after relaunch.)
    func append(_ ops: [Op]) throws
    func loadInk(page: UUID) throws -> Data?
    func saveInk(_ data: Data, page: UUID) throws
    /// Debounced/background saves use this non-blocking path. A synchronous `saveInk` remains available
    /// for page switches and teardown, where it acts as a barrier behind all previously queued writes.
    func saveInkAsync(_ data: Data, page: UUID, completion: @escaping (Error?) -> Void)
}

extension JournalStorage {
    func saveInkAsync(_ data: Data, page: UUID, completion: @escaping (Error?) -> Void) {
        do { try saveInk(data, page: page); completion(nil) }
        catch { completion(error) }
    }
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
    private let inkWriteQueue = DispatchQueue(label: "com.ryanrudat.InkLab.ink-writes", qos: .utility)

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

    func loadOps() throws -> [Op] {
        guard FileManager.default.fileExists(atPath: opLogURL.path) else { return [] }
        let data = try Data(contentsOf: opLogURL)
        guard !data.isEmpty else { return [] }
        // IMPORTANT: keep the encoder COMPACT — compact JSON escapes newlines (\n), so one op == one
        // line. (Enabling .prettyPrinted would emit literal newlines and break this splitting.)
        // Every completed append ends in a newline. A malformed final record is only a benign crash
        // tail when that newline is absent; a fully-written-but-unreadable last line is corruption too.
        let hasCompleteFinalRecord = data.last == 0x0A
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if hasCompleteFinalRecord { lines.removeLast() } // the expected empty segment after final "\n"
        var ops: [Op] = []
        var interiorFailures = 0, tornTail = false
        for (idx, line) in lines.enumerated() {
            if let op = try? decoder.decode(Op.self, from: Data(line)) {
                ops.append(op)
            } else if idx == lines.count - 1 && !hasCompleteFinalRecord {
                tornTail = true            // expected: a kill mid-append can only tear the LAST line
            } else {
                interiorFailures += 1      // unexpected: mid-file corruption or a forward-incompatible op
            }
        }
        if tornTail {
            // Remove the incomplete bytes before allowing another append. Leaving them at EOF would
            // concatenate the next valid JSON record onto the torn one and turn a recoverable tail into
            // permanent corruption on the next launch.
            let completeByteCount: UInt64
            if let newline = data.lastIndex(of: 0x0A) {
                completeByteCount = UInt64(data.distance(from: data.startIndex, to: newline) + 1)
            } else {
                completeByteCount = 0
            }
            do {
                let handle = try FileHandle(forWritingTo: opLogURL)
                defer { try? handle.close() }
                try handle.truncate(atOffset: completeByteCount)
                try handle.synchronize()
                log.info("op-log: repaired a torn final line (kill mid-write) — expected, safe")
            } catch {
                log.error("op-log torn-tail repair failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        } else if !hasCompleteFinalRecord {
            // The JSON bytes can finish before the trailing newline does. Preserve that fully decoded op,
            // but restore the delimiter now so the next append cannot concatenate two JSON documents.
            do {
                let handle = try FileHandle(forWritingTo: opLogURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0x0A]))
                try handle.synchronize()
                log.info("op-log: restored a missing final record delimiter")
            } catch {
                log.error("op-log delimiter repair failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
        if interiorFailures > 0 {
            // The append path only ever GROWS the file (seekToEnd), so an interior line can never be a
            // torn tail — this is real on-disk corruption or a forward-incompatible op from a newer
            // client. Surface it loudly (previously it was silently lumped in with the benign torn tail).
            // TODO (ADR 0004): add a quarantine + raster-fallback recovery flow.
            log.error("op-log: \(interiorFailures) INTERIOR unreadable op(s) of \(lines.count) — possible corruption; replay may be incomplete")
            throw JournalStorageError.corruptOpLog(unreadableLines: interiorFailures, totalLines: lines.count)
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
            if FileManager.default.fileExists(atPath: opLogURL.path) {
                let handle = try FileHandle(forWritingTo: opLogURL)
                defer { try? handle.close() }
                try handle.seekToEnd()           // always true EOF — the file only grows, never corrupts earlier ops
                try handle.write(contentsOf: blob)
                try handle.synchronize()         // fsync: shrink the torn-tail window on a crash mid-write
            } else {
                try blob.write(to: opLogURL, options: .atomic)   // first write — create it
            }
        } catch {
            log.error("op-log append failed: \(error.localizedDescription, privacy: .public)")
            throw error   // propagate so JournalStore can surface "not saved" instead of silent loss
        }
    }

    func loadInk(page: UUID) throws -> Data? {
        let url = inkURL(page)
        return try inkWriteQueue.sync {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }
    }
    func saveInk(_ data: Data, page: UUID) throws {
        let url = inkURL(page)
        do {
            try inkWriteQueue.sync { try data.write(to: url, options: .atomic) }
        } catch {
            log.error("ink save failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
    func saveInkAsync(_ data: Data, page: UUID, completion: @escaping (Error?) -> Void) {
        let url = inkURL(page)
        let logger = log
        inkWriteQueue.async {
            let failure: Error?
            do { try data.write(to: url, options: .atomic); failure = nil }
            catch {
                logger.error("ink save failed: \(error.localizedDescription, privacy: .public)")
                failure = error
            }
            DispatchQueue.main.async { completion(failure) }
        }
    }
    private func inkURL(_ page: UUID) -> URL { inkDir.appendingPathComponent("\(page.uuidString).drawing") }
}
