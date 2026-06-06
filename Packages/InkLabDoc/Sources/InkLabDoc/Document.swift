import Foundation

// The journal engine: fold (replay), invert (undo), merge (sync), remap (cross-notebook paste),
// and a compaction equivalence used by the snapshot store. Pure, deterministic, value-in/value-out.

// MARK: - Fold (replay the journal into a page)

/// Replay `ops` (in HLC total order) into a projection. Pass `base` to continue from a compacted
/// snapshot — ops at or before `base.highWaterHLC` are skipped, so folding is incremental.
public func fold(_ ops: [Op], notebookID: UUID, from base: NotebookProjection? = nil) -> NotebookProjection {
    var proj = base ?? NotebookProjection(id: notebookID)
    let lowWater = base?.highWaterHLC
    let applicable = ops
        .filter { lowWater == nil || $0.hlc > lowWater! }
        .sorted { $0.hlc < $1.hlc }
    for op in applicable {
        apply(op, to: &proj)
        if let hw = proj.highWaterHLC { if op.hlc > hw { proj.highWaterHLC = op.hlc } }
        else { proj.highWaterHLC = op.hlc }
    }
    return proj
}

private func ensurePage(_ pageID: UUID, in proj: inout NotebookProjection) {
    if proj.pages[pageID] == nil {
        proj.pages[pageID] = PageProjection(id: pageID)
        proj.pageOrder.append(pageID)
    }
}

private func findPage(of objectID: UUID, in proj: NotebookProjection) -> UUID? {
    for (pid, page) in proj.pages where page.objects[objectID] != nil { return pid }
    return nil
}

private func apply(_ op: Op, to proj: inout NotebookProjection) {
    switch op.payload {
    case .addPage(let meta):
        ensurePage(meta.pageID, in: &proj)
        proj.pages[meta.pageID]?.extentY = meta.extentY
    case .setPageExtent(let pageID, _, let new):
        ensurePage(pageID, in: &proj)
        proj.pages[pageID]?.extentY = new
    case .addObject(let snap), .aiInsert(let snap, _):
        ensurePage(snap.pageID, in: &proj)
        proj.pages[snap.pageID]?.objects[snap.objectID] = snap
    case .delete(let id):
        if let pid = findPage(of: id, in: proj) { proj.pages[pid]?.objects[id]?.isDeleted = true }
    case .restore(let id):
        if let pid = findPage(of: id, in: proj) { proj.pages[pid]?.objects[id]?.isDeleted = false }
    case .setTransform(let id, _, let new):
        if let pid = findPage(of: id, in: proj) { proj.pages[pid]?.objects[id]?.transform = new }
    case .setZ(let id, _, let new):
        if let pid = findPage(of: id, in: proj) { proj.pages[pid]?.objects[id]?.z = new }
    case .setInk(let id, _, let new):
        if let pid = findPage(of: id, in: proj), var obj = proj.pages[pid]?.objects[id], case .ink(var b) = obj.payload {
            b.blob = new; obj.payload = .ink(b); proj.pages[pid]?.objects[id] = obj
        }
    case .setProps(let id, _, let new):
        if let pid = findPage(of: id, in: proj), var obj = proj.pages[pid]?.objects[id] {
            applyPatch(new, to: &obj); proj.pages[pid]?.objects[id] = obj
        }
    case .addEdge(let edge):
        proj.edges[edge.id] = edge
    case .removeEdge(let edge):
        proj.edges[edge.id] = nil
    }
}

private func applyPatch(_ patch: PropPatch, to obj: inout ObjectSnapshot) {
    switch obj.payload {
    case .sticky(var text, var color):
        if let t = patch.stickyText { text = t }
        if let c = patch.colorHex { color = c }
        obj.payload = .sticky(text: text, colorHex: color)
    case .recognized(var body):
        if let r = patch.readAs { body.readAs = r }
        obj.payload = .recognized(body)
    default:
        break
    }
}

// MARK: - Invert (undo = append the inverse op)

/// The inverse of a single op, as a brand-new op (fresh id/hlc from `clock`), tagged `undoesOpID`
/// and optionally grouped under `txn`. Undo is durable and merge-safe because it is just more log.
public func invert(_ op: Op, txn: UUID?, using clock: Clock) -> Op {
    let inv: OpPayload
    switch op.payload {
    case .addObject(let s), .aiInsert(let s, _):
        inv = .delete(objectID: s.objectID)
    case .delete(let id):
        inv = .restore(objectID: id)
    case .restore(let id):
        inv = .delete(objectID: id)
    case .setTransform(let id, let old, let new):
        inv = .setTransform(objectID: id, old: new, new: old)
    case .setZ(let id, let old, let new):
        inv = .setZ(objectID: id, old: new, new: old)
    case .setInk(let id, let old, let new):
        inv = .setInk(objectID: id, old: new, new: old ?? new)
    case .setProps(let id, let old, let new):
        inv = .setProps(objectID: id, old: new, new: old)
    case .addEdge(let e):
        inv = .removeEdge(edge: e)
    case .removeEdge(let e):
        inv = .addEdge(edge: e)
    case .addPage(let m):
        inv = .addPage(meta: m)               // page removal is not modeled; addPage is idempotent
    case .setPageExtent(let id, let old, let new):
        inv = .setPageExtent(pageID: id, old: new, new: old)
    }
    return Op(id: clock.nextOpID(), hlc: clock.tick(), schemaVersion: op.schemaVersion,
                     notebookID: op.notebookID, transactionID: txn, undoesOpID: op.id, payload: inv)
}

/// Undo a whole transaction as ONE step: invert every op in the transaction, in reverse order,
/// grouped under a single new transactionID. (AI insertions undo cleanly because they ARE a txn.)
public func undoTransaction(_ transactionID: UUID, in log: [Op], using clock: Clock) -> [Op] {
    let group = log.filter { $0.transactionID == transactionID }.sorted { $0.hlc < $1.hlc }
    let undoTxn = clock.actor                              // any stable UUID; reuse the actor id for grouping
    return group.reversed().map { invert($0, txn: undoTxn, using: clock) }
}

// MARK: - Merge (sync = sort-union two logs by HLC, then fold)

/// Deterministically merge two op logs. Dedups by OpID, orders by HLC, re-folds. Convergent:
/// merge(a,b) == merge(b,a), and no op (hence no stroke) is dropped.
public func merge(_ a: [Op], _ b: [Op], notebookID: UUID) -> NotebookProjection {
    var byID: [OpID: Op] = [:]
    for op in a + b { byID[op.id] = op }
    return fold(Array(byID.values), notebookID: notebookID)
}

// MARK: - Remap (cross-notebook / cross-page paste with reference rewriting)

/// Rewrite a slice of ops into a new notebook/page, remapping object/page/edge ids (and internal
/// refs: group children, callout sources) via `idMap`, with fresh OpIDs. Plain-UUID references make
/// this a simple remap rather than pointer surgery.
public func remap(_ ops: [Op], idMap: [UUID: UUID], newNotebookID: UUID, using clock: Clock) -> [Op] {
    func m(_ id: UUID) -> UUID { idMap[id] ?? id }
    func remapPayload(_ p: ObjectPayload) -> ObjectPayload {
        switch p {
        case .group(let ids): return .group(childIDs: ids.map(m))
        case .callout(let t, let src, let prov): return .callout(text: t, sourceObjectIDs: src.map(m), provenanceJSON: prov)
        default: return p
        }
    }
    func remapSnapshot(_ s: ObjectSnapshot) -> ObjectSnapshot {
        var s2 = s
        s2.objectID = m(s.objectID); s2.pageID = m(s.pageID); s2.payload = remapPayload(s.payload)
        return s2
    }
    func remapEdge(_ e: DependencyEdge) -> DependencyEdge {
        DependencyEdge(id: m(e.id), from: m(e.from), fromField: e.fromField, to: m(e.to), toField: e.toField, fnID: e.fnID)
    }
    return ops.map { op in
        let payload: OpPayload
        switch op.payload {
        case .addObject(let s): payload = .addObject(snapshot: remapSnapshot(s))
        case .aiInsert(let s, let prov): payload = .aiInsert(snapshot: remapSnapshot(s), provenanceJSON: prov)
        case .delete(let id): payload = .delete(objectID: m(id))
        case .restore(let id): payload = .restore(objectID: m(id))
        case .setTransform(let id, let o, let n): payload = .setTransform(objectID: m(id), old: o, new: n)
        case .setZ(let id, let o, let n): payload = .setZ(objectID: m(id), old: o, new: n)
        case .setInk(let id, let o, let n): payload = .setInk(objectID: m(id), old: o, new: n)
        case .setProps(let id, let o, let n): payload = .setProps(objectID: m(id), old: o, new: n)
        case .addEdge(let e): payload = .addEdge(edge: remapEdge(e))
        case .removeEdge(let e): payload = .removeEdge(edge: remapEdge(e))
        case .addPage(let mm): payload = .addPage(meta: PageMeta(pageID: m(mm.pageID), index: mm.index, extentY: mm.extentY))
        case .setPageExtent(let id, let o, let n): payload = .setPageExtent(pageID: m(id), old: o, new: n)
        }
        return Op(id: clock.nextOpID(), hlc: clock.tick(), schemaVersion: op.schemaVersion,
                         notebookID: newNotebookID, transactionID: op.transactionID, undoesOpID: nil, payload: payload)
    }
}

// MARK: - Clock (monotonic OpID + HLC generator)

/// Generates unique OpIDs and monotonically increasing HLCs for one actor. Not Sendable by design —
/// each editing context owns its own clock on its own thread.
public final class Clock {
    public let actor: UUID
    private var wall: UInt64
    private var counter: UInt16 = 0
    private var opCounter: UInt64 = 0
    public init(actor: UUID = UUID(), startWall: UInt64 = 0) { self.actor = actor; self.wall = startWall }
    public func tick() -> HLC { counter &+= 1; return HLC(wallMillis: wall, counter: counter, actor: actor) }
    public func nextOpID() -> OpID { opCounter += 1; return OpID(actor: actor, counter: opCounter) }
    /// Advance the wall component (used in tests so undo/remap ops sort AFTER the original log).
    public func advance(toWall w: UInt64) { if w > wall { wall = w; counter = 0 } }
}
