import XCTest
@testable import InkLabDoc
import InkLabRecognition

/// These tests pin down the "journal" foundation as executable proof of the brief's non-negotiables:
/// never-lose-ink on merge, global undo (incl. AI insertions undoing as one step), deterministic
/// convergence, forward-compatible serialization, and compaction that can't resurrect deleted work.
final class DocumentTests: XCTestCase {

    // Deterministic RNG so the fuzz tests are reproducible.
    struct LCG: RandomNumberGenerator {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
    }

    // MARK: builders
    func sticky(_ page: UUID, _ actor: UUID, _ text: String) -> ObjectSnapshot {
        ObjectSnapshot(objectID: UUID(), kind: .sticky, pageID: page, createdBy: actor, payload: .sticky(text: text, colorHex: "#FFEE88"))
    }
    func ink(_ page: UUID, _ actor: UUID, strokes: [UUID]) -> ObjectSnapshot {
        ObjectSnapshot(objectID: UUID(), kind: .ink, pageID: page, createdBy: actor,
                       payload: .ink(InkBody(blob: BlobRef(id: UUID(), kind: .inkPKDrawing, inkContentVersion: 3, fallbackRasterID: UUID(), byteCount: 64),
                                             bounds: Rect(x: 0, y: 0, width: 10, height: 10), strokeIDs: strokes)))
    }
    func op(_ clock: Clock, _ nb: UUID, _ p: OpPayload, txn: UUID? = nil) -> Op {
        Op(id: clock.nextOpID(), hlc: clock.tick(), notebookID: nb, transactionID: txn, payload: p)
    }
    func allStrokeIDs(_ proj: NotebookProjection) -> Set<UUID> {
        var s = Set<UUID>()
        for page in proj.pages.values { for obj in page.objects.values { if case .ink(let b) = obj.payload { s.formUnion(b.strokeIDs) } } }
        return s
    }
    func visible(_ proj: NotebookProjection, _ page: UUID) -> [ObjectSnapshot] {
        (proj.pages[page]?.objects.values.filter { !$0.isDeleted }) ?? []
    }

    // MARK: - A. Codable round-trip for every payload kind + forward-compat fallthrough
    func test_A_codableRoundTrip_andForwardCompat() throws {
        let payloads: [ObjectPayload] = [
            .ink(InkBody(blob: BlobRef(id: UUID(), kind: .inkPKDrawing, inkContentVersion: 3, fallbackRasterID: UUID(), byteCount: 42),
                         bounds: Rect(x: 0, y: 0, width: 5, height: 5), strokeIDs: [UUID(), UUID()])),
            .recognized(RecognizedBody(formal: .expressionTree(.binary(op: "+", lhs: .symbol("x"), rhs: .number(3))),
                                       readAs: "x + 3", confidence: 0.91,
                                       alternatives: [Candidate(formal: .latex("x+3"), readAs: "x+3", confidence: 0.5)],
                                       sourceStrokeIDs: [UUID()],
                                       bindings: [ReactiveBinding(nodePath: "rhs", kind: .knob, lower: 0, upper: 10)])),
            .widget(html: BlobRef(id: UUID(), kind: .widgetBundle, byteCount: 9), jsState: "{}", sandboxPolicy: "strict"),
            .sticker(image: BlobRef(id: UUID(), kind: .stickerPNG, byteCount: 7), vectorPDF: nil),
            .sticky(text: "remember", colorHex: "#FFEE88"),
            .callout(text: "= 7", sourceObjectIDs: [UUID()], provenanceJSON: "{\"model\":\"claude\"}"),
            .chart(specJSON: "{}", dataRef: UUID()),
            .object3D(scene: BlobRef(id: UUID(), kind: .usdz, byteCount: 11), cameraJSON: "{}"),
            .group(childIDs: [UUID(), UUID()]),
        ]
        for p in payloads {
            let data = try Canonical.encode(p)
            let back = try Canonical.decode(ObjectPayload.self, data)
            XCTAssertEqual(p, back, "payload must survive a Codable round-trip")
            XCTAssertEqual(try Canonical.encode(back), data, "re-encode must be byte-stable")
        }
        // Forward-compat: a payload whose `type` this build doesn't know lands in `.unknown`,
        // preserved verbatim through decode+re-encode (so an older client never destroys newer data).
        let futureBytes = Data("{\"spin\":3,\"color\":\"red\"}".utf8)
        let future = ObjectPayload.unknown(rawType: "hologram", json: futureBytes)
        let wire = try Canonical.encode(future)
        let decoded = try Canonical.decode(ObjectPayload.self, wire)
        guard case .unknown(let rt, let j) = decoded else { return XCTFail("unknown type must fall through to .unknown") }
        XCTAssertEqual(rt, "hologram"); XCTAssertEqual(j, futureBytes)
        XCTAssertEqual(try Canonical.encode(decoded), wire)
    }

    // MARK: - B. Undo of mutations is an exact round-trip
    func test_B_undoMutations_exactRoundTrip() {
        let nb = UUID(), page = UUID(), me = UUID()
        let c = Clock(actor: me, startWall: 10)
        let s = sticky(page, me, "hi"); let sid = s.objectID
        let base = [op(c, nb, .addPage(meta: PageMeta(pageID: page, index: 0, extentY: 0))),
                    op(c, nb, .addObject(snapshot: s))]
        let content = [op(c, nb, .setTransform(objectID: sid, old: Transform(), new: Transform(x: 50, y: 60))),
                       op(c, nb, .setProps(objectID: sid, old: PropPatch(stickyText: "hi"), new: PropPatch(stickyText: "bye")))]
        let baseProj = fold(base, notebookID: nb)
        let undoClock = Clock(startWall: 1000)
        let undo = content.reversed().map { invert($0, txn: nil, using: undoClock) }
        let finalProj = fold(base + content + undo, notebookID: nb)
        XCTAssertEqual(finalProj.pages[page]?.objects[sid], baseProj.pages[page]?.objects[sid],
                       "after undo, the object must be byte-identical to before the edits")
    }

    // MARK: - B2/B3. AI insertion undoes as ONE grouped step
    func test_B3_aiInsert_undoesAsOneStep() {
        let nb = UUID(), page = UUID(), me = UUID()
        let c = Clock(actor: me, startWall: 10)
        let target = sticky(page, me, "x+3"); _ = target
        let callout = ObjectSnapshot(objectID: UUID(), kind: .callout, pageID: page, createdBy: me, payload: .callout(text: "= 7", sourceObjectIDs: [target.objectID], provenanceJSON: "{}"))
        let widget = ObjectSnapshot(objectID: UUID(), kind: .widget, pageID: page, createdBy: me, payload: .widget(html: BlobRef(id: UUID(), kind: .widgetBundle, byteCount: 1), jsState: "{}", sandboxPolicy: "strict"))
        let edge = DependencyEdge(id: UUID(), from: callout.objectID, fromField: "value", to: target.objectID, toField: "rhs", fnID: "eval")
        let T = UUID()
        let base = [op(c, nb, .addPage(meta: PageMeta(pageID: page, index: 0, extentY: 0))),
                    op(c, nb, .addObject(snapshot: target))]
        let aiLog = [op(c, nb, .aiInsert(snapshot: callout, provenanceJSON: "{}"), txn: T),
                     op(c, nb, .aiInsert(snapshot: widget, provenanceJSON: "{}"), txn: T),
                     op(c, nb, .addEdge(edge: edge), txn: T)]
        let log = base + aiLog
        let proj = fold(log, notebookID: nb)
        XCTAssertEqual(visible(proj, page).count, 3, "target + callout + widget visible")
        XCTAssertNotNil(proj.edges[edge.id])

        let undoClock = Clock(startWall: 1000)
        let undo = undoTransaction(T, in: log, using: undoClock)
        XCTAssertEqual(undo.count, 3, "the whole AI insertion inverts in one group")
        XCTAssertEqual(Set(undo.map { $0.transactionID }), [undoClock.actor], "grouped under one undo transaction")

        let after = fold(log + undo, notebookID: nb)
        XCTAssertEqual(visible(after, page).map(\.objectID), [target.objectID], "only the user's original object remains")
        XCTAssertNil(after.edges[edge.id], "the AI's dependency edge is gone too")
    }

    // MARK: - C. Deterministic convergence (order-independent) + HLC last-writer-wins
    func test_C_foldIsOrderIndependent_and_LWW() {
        let nb = UUID(), page = UUID(), me = UUID()
        let c = Clock(actor: me, startWall: 10)
        let s = sticky(page, me, "a"); let sid = s.objectID
        var ops = [op(c, nb, .addPage(meta: PageMeta(pageID: page, index: 0, extentY: 0))),
                   op(c, nb, .addObject(snapshot: s)),
                   op(c, nb, .setTransform(objectID: sid, old: Transform(), new: Transform(x: 1))),
                   op(c, nb, .setTransform(objectID: sid, old: Transform(x: 1), new: Transform(x: 2)))]  // higher HLC -> wins
        let ref = fold(ops, notebookID: nb)
        var rng = LCG(7)
        XCTAssertEqual(fold(ops.reversed(), notebookID: nb), ref, "fold must ignore input order")
        ops.shuffle(using: &rng)
        XCTAssertEqual(fold(ops, notebookID: nb), ref, "fold of a shuffled log converges identically")
        XCTAssertEqual(ref.pages[page]?.objects[sid]?.transform.x, 2, "the highest-HLC write wins (LWW)")
    }

    // MARK: - D. Merge never loses a stroke and is commutative
    func test_D_merge_neverLosesInk_and_commutes() {
        let nb = UUID(), page = UUID()
        let common = Clock(actor: UUID(), startWall: 5)
        let base = [op(common, nb, .addPage(meta: PageMeta(pageID: page, index: 0, extentY: 0)))]

        let aClock = Clock(actor: UUID(), startWall: 20)
        let inkA = ink(page, aClock.actor, strokes: [UUID(), UUID()])
        let streamA = base + [op(aClock, nb, .addObject(snapshot: inkA)),
                              op(aClock, nb, .setTransform(objectID: inkA.objectID, old: Transform(), new: Transform(x: 9)))]

        let bClock = Clock(actor: UUID(), startWall: 20)
        let inkB = ink(page, bClock.actor, strokes: [UUID(), UUID(), UUID()])
        let streamB = base + [op(bClock, nb, .addObject(snapshot: inkB))]

        let merged = merge(streamA, streamB, notebookID: nb)
        let expected = Set(inkA.strokeIDs() + inkB.strokeIDs())
        XCTAssertTrue(allStrokeIDs(merged).isSuperset(of: expected), "no stroke may be lost when two devices merge")
        XCTAssertEqual(visible(merged, page).count, 2, "both devices' ink objects survive")
        XCTAssertEqual(merge(streamA, streamB, notebookID: nb), merge(streamB, streamA, notebookID: nb), "merge is commutative/convergent")
    }

    // MARK: - E. Compaction equivalence — folding a prefix into a snapshot then applying the rest
    //            must equal a full replay, even with delete/restore (no resurrection of deleted work).
    func test_E_compactionEquivalence_fuzz() {
        for seed in UInt64(1)...25 {
            var rng = LCG(seed)
            let nb = UUID(), page = UUID(), me = UUID()
            let c = Clock(actor: me, startWall: 5)
            var ops = [op(c, nb, .addPage(meta: PageMeta(pageID: page, index: 0, extentY: 0)))]
            var ids: [UUID] = []
            let steps = 12 + Int(rng.next() % 24)
            for _ in 0..<steps {
                if ids.isEmpty || rng.next() % 100 < 35 {
                    let snap = sticky(page, me, "n"); ids.append(snap.objectID)
                    ops.append(op(c, nb, .addObject(snapshot: snap)))
                } else {
                    let oid = ids[Int(rng.next() % UInt64(ids.count))]
                    let r = rng.next() % 100
                    let payload: OpPayload = r < 40 ? .setTransform(objectID: oid, old: Transform(), new: Transform(x: Double(r)))
                                          : (r < 70 ? .delete(objectID: oid) : .restore(objectID: oid))
                    ops.append(op(c, nb, payload))
                }
            }
            let sorted = ops.sorted { $0.hlc < $1.hlc }
            let k = max(1, sorted.count / 2)
            let snapshot = fold(Array(sorted[0..<k]), notebookID: nb)        // "compact" the prefix
            let compacted = fold(Array(sorted[k...]), notebookID: nb, from: snapshot)  // apply the tail
            XCTAssertEqual(compacted, fold(ops, notebookID: nb), "seed \(seed): compaction must equal full replay")
        }
    }

    // MARK: - F2. HLC stays strictly monotonic across the 16-bit counter boundary
    /// Regression: tick() used a WRAPPING counter (UInt16 `&+=`), so after 65,535 ops in one session
    /// the next HLC was SMALLER than the first — corrupting fold's total order. tick() must now stay
    /// strictly increasing past the wrap point (it advances the wall and resets the counter).
    func test_F2_hlcMonotonicAcrossCounterWrap() {
        let c = Clock(actor: UUID(), startWall: 1)
        var prev = c.tick()
        for _ in 0..<70_000 {              // well past UInt16.max (65,535)
            let next = c.tick()
            XCTAssertTrue(prev < next, "HLC must be strictly increasing across the counter-wrap boundary")
            prev = next
        }
    }

    // MARK: - G. Live-object state edits + promote (the make-real substrate) undo in one step
    func test_G_liveStateEdit_undoesExactly() {
        let nb = UUID(), page = UUID(), me = UUID()
        let c = Clock(actor: me, startWall: 10)
        let w = ObjectSnapshot(objectID: UUID(), kind: .widget, pageID: page, createdBy: me,
                               payload: .widget(html: BlobRef(id: UUID(), kind: .widgetBundle, byteCount: 1),
                                                jsState: "{\"display\":\"0\"}", sandboxPolicy: "native"))
        let wid = w.objectID
        let base = [op(c, nb, .addPage(meta: PageMeta(pageID: page, index: 0, extentY: 0))),
                    op(c, nb, .addObject(snapshot: w))]
        let baseProj = fold(base, notebookID: nb)

        let edit = [op(c, nb, .setObjectState(objectID: wid, old: "{\"display\":\"0\"}", new: "{\"display\":\"42\"}"))]
        let edited = fold(base + edit, notebookID: nb)
        guard case .widget(_, let js, _)? = edited.pages[page]?.objects[wid]?.payload else { return XCTFail("widget payload") }
        XCTAssertEqual(js, "{\"display\":\"42\"}", "setObjectState mutates jsState in place")

        let uc = Clock(startWall: 1000)
        let undo = edit.reversed().map { invert($0, txn: nil, using: uc) }
        let afterUndo = fold(base + edit + undo, notebookID: nb)
        XCTAssertEqual(afterUndo.pages[page]?.objects[wid], baseProj.pages[page]?.objects[wid],
                       "undo of a state edit restores the object exactly (one step)")
    }

    func test_G2_promote_swapsPayloadAndKind_andUndoes() {
        let nb = UUID(), page = UUID(), me = UUID()
        let c = Clock(actor: me, startWall: 10)
        let stickerPayload = ObjectPayload.sticker(image: BlobRef(id: UUID(), kind: .stickerPNG, byteCount: 5), vectorPDF: nil)
        let s = ObjectSnapshot(objectID: UUID(), kind: .sticker, pageID: page, createdBy: me, payload: stickerPayload)
        let sid = s.objectID
        let base = [op(c, nb, .addPage(meta: PageMeta(pageID: page, index: 0, extentY: 0))),
                    op(c, nb, .addObject(snapshot: s))]
        let baseProj = fold(base, notebookID: nb)

        // promote sticker → interactive widget (energy level up), identity preserved
        let widgetPayload = ObjectPayload.widget(html: BlobRef(id: UUID(), kind: .widgetBundle, byteCount: 2), jsState: "{}", sandboxPolicy: "native")
        let promote = [op(c, nb, .promote(objectID: sid, old: stickerPayload, new: widgetPayload))]
        let promoted = fold(base + promote, notebookID: nb)
        XCTAssertEqual(promoted.pages[page]?.objects[sid]?.kind, .widget, "promote keeps kind consistent with the new payload")
        XCTAssertEqual(promoted.pages[page]?.objects[sid]?.objectID, sid, "identity is preserved across promote")
        if case .widget? = promoted.pages[page]?.objects[sid]?.payload {} else { XCTFail("payload swapped to widget") }

        let uc = Clock(startWall: 2000)
        let undo = promote.reversed().map { invert($0, txn: nil, using: uc) }
        let afterUndo = fold(base + promote + undo, notebookID: nb)
        XCTAssertEqual(afterUndo.pages[page]?.objects[sid], baseProj.pages[page]?.objects[sid],
                       "undo of a promote restores the original payload AND kind")
    }

    // MARK: - F. Cross-notebook paste rewrites references consistently
    func test_F_crossNotebookPaste_remapsRefs() {
        let nb1 = UUID(), page = UUID(), me = UUID()
        let c = Clock(actor: me, startWall: 10)
        let a = sticky(page, me, "A"); let b = sticky(page, me, "B")
        let edge = DependencyEdge(id: UUID(), from: a.objectID, fromField: "v", to: b.objectID, toField: "w", fnID: "f")
        let source = [op(c, nb1, .addPage(meta: PageMeta(pageID: page, index: 0, extentY: 0))),
                      op(c, nb1, .addObject(snapshot: a)),
                      op(c, nb1, .addObject(snapshot: b)),
                      op(c, nb1, .addEdge(edge: edge))]

        let nb2 = UUID(), newPage = UUID(), newA = UUID(), newB = UUID(), newEdge = UUID()
        let idMap = [page: newPage, a.objectID: newA, b.objectID: newB, edge.id: newEdge]
        let pasteClock = Clock(actor: UUID(), startWall: 2000)
        let pasted = remap(source, idMap: idMap, newNotebookID: nb2, using: pasteClock)
        let proj2 = fold(pasted, notebookID: nb2)

        XCTAssertNotNil(proj2.pages[newPage]?.objects[newA], "pasted object A exists under its new id")
        XCTAssertNotNil(proj2.pages[newPage]?.objects[newB], "pasted object B exists under its new id")
        XCTAssertEqual(proj2.edges[newEdge]?.from, newA, "edge endpoints are remapped to the new ids")
        XCTAssertEqual(proj2.edges[newEdge]?.to, newB)
        // the source notebook is untouched by the paste
        let proj1 = fold(source, notebookID: nb1)
        XCTAssertNotNil(proj1.pages[page]?.objects[a.objectID])
        XCTAssertEqual(proj1.edges[edge.id]?.from, a.objectID)
    }
}

// Small convenience used by the merge test.
private extension ObjectSnapshot {
    func strokeIDs() -> [UUID] { if case .ink(let b) = payload { return b.strokeIDs }; return [] }
}
