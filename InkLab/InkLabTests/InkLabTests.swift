import Testing
import UIKit
import WebKit
import PencilKit
import InkLabKit
@testable import InkLab

/// Verifies the pure-Swift, on-device loop the app exposes: the deterministic engines reachable from
/// the "@" bar and the recognition chips, plus the Apple Vision recognizer reading a rendered image.
struct InkLabTests {

    // MARK: - Engine chips (recognition review)

    @Test func redPenCatchesAWrongLine() {
        // x + 2 = 5  ⇒  x = 3, so "x = 4" changes the solution set (wrong on line 2).
        let wrong = runEngine(.check, on: "x + 2 = 5\nx = 4")
        #expect(wrong.contains("✗"))
        #expect(wrong.contains("2"))   // points at line 2
        let right = runEngine(.check, on: "x + 2 = 5\nx = 3")
        #expect(right.contains("✓"))
    }

    @Test func differentiateSimplifies() {
        let d = runEngine(.differentiate, on: "x^2")
        #expect(d.contains("2x"))      // raw 2·x^1·1 simplified to 2x
    }

    /// Regression for the renderer precedence bug: d/dx(1/(2x)) must NOT print as "-2/2x^2"
    /// (which reads as -x²). The power base (2x) has to stay parenthesized.
    @Test func differentiateParenthesizesCorrectly() {
        let d = runEngine(.differentiate, on: "1/(2x)")
        #expect(d.contains("(2x)^2"))      // denominator (2x)^2 kept grouped
        #expect(!d.contains("2x^2"))       // the wrong, ungrouped form must not appear
        // Negative exponent stays grouped, and no "- -" artifacts leak through.
        let e = runEngine(.differentiate, on: "x^-1")
        #expect(!e.contains("- -"))
    }

    @Test func chemistryEngines() {
        #expect(runEngine(.balance, on: "H2 + O2 -> H2O").contains("H2O"))
        #expect(runEngine(.molarMass, on: "H2O").contains("18"))
    }

    @Test func unitsEngine() {
        #expect(runEngine(.units, on: "5 m + 3 s").contains("✗"))   // length + time is a mismatch
        #expect(runEngine(.units, on: "5 m + 3 m").contains("✓"))
    }

    @Test func biologyEngines() {
        #expect(runEngine(.dna, on: "ATGGCC").contains("→"))
        let cross = runEngine(.punnett, on: "Aa x Aa")
        #expect(cross.contains("→"))
        #expect(!cross.contains("Use e.g."))
    }

    // MARK: - "@" command bar

    @Test func atBarRoutesToRealEngines() {
        #expect(runCommand("@balance H2 + O2 -> H2O").contains("H2O"))
        #expect(runCommand("@check x + 2 = 5; x = 4").contains("✗"))   // ';' splits steps
        #expect(runCommand("@differentiate x^2").contains("2x"))
        #expect(runCommand("@units 5 m + 3 s").contains("✗"))
        // @transcribe is DNA→mRNA (T→U), NOT DNA→protein — assert the actual mRNA, not just an arrow.
        #expect(runCommand("@transcribe ATGGCC").contains("AUGGCC"))
        #expect(!runCommand("@transcribe ATGGCC").contains("protein"))
        // @translate is mRNA→protein and must ACCEPT RNA (U) input rather than rejecting it as "not DNA".
        #expect(runCommand("@translate AUGGCC").contains("protein"))
        #expect(!runCommand("@translate AUGGCC").lowercased().contains("not valid"))
        #expect(runCommand("@punnett Aa x Aa").contains("→"))
    }

    /// Handwritten / typed "@" commands route correctly: known verbs → exact engines, else → make-real.
    @Test func commandRouting() {
        #expect(isDeterministicEngineCommand("@check x+2=5; x=3"))
        #expect(isDeterministicEngineCommand("@balance H2 + O2 -> H2O"))
        #expect(isDeterministicEngineCommand("@molar C6H12O6"))
        #expect(!isDeterministicEngineCommand("@a pendulum"))            // → make-real generation
        #expect(!isDeterministicEngineCommand("@scientific calculator")) // → make-real generation (Claude)
        #expect(makeRealPrompt("@a pendulum") == "a pendulum")           // leading @ stripped for Claude
        #expect(makeRealPrompt("a clock") == "a clock")
    }

    /// The auto-scan must read EVERY "@" on the page, not just the first — multiple commands per scan.
    @MainActor
    @Test func extractsEveryAtCommand() {
        #expect(CanvasViewController.extractAtCommands("@calculator") == ["@calculator"])
        #expect(CanvasViewController.extractAtCommands("@a clock\n@a piano") == ["@a clock", "@a piano"])
        #expect(CanvasViewController.extractAtCommands("notes @balance H2 @molar C6") == ["@balance H2", "@molar C6"])
        #expect(CanvasViewController.extractAtCommands("@a @b").count == 2)
        #expect(CanvasViewController.extractAtCommands("just plain notes").isEmpty)
    }

    /// Regression: `@molar` is NOT one of InkLabRouter's verbs, so it used to fall through to
    /// "make-real" and never computed. CommandRunner now detects it explicitly.
    @Test func molarCommandIsWired() {
        let r = runCommand("@molar C6H12O6")
        #expect(r.contains("g/mol"))
        #expect(r.contains("180"))     // glucose ≈ 180.156 g/mol
        #expect(runCommand("@molar mass H2O").contains("g/mol"))
    }

    // MARK: - Native widget: scientific calculator (engine-backed, correct-or-silent)

    @MainActor
    @Test func calculatorComputesViaEngine() {
        #expect(CalculatorWidgetView.evaluate("2+3*4") == "14")     // precedence via the CAS
        #expect(CalculatorWidgetView.evaluate("(2+3)*4") == "20")
        #expect(CalculatorWidgetView.evaluate("sqrt(9)") == "3")
        #expect(CalculatorWidgetView.evaluate("2^10") == "1024")
        #expect(CalculatorWidgetView.evaluate("1/0") == nil)        // undefined → silent (UI shows Error)
        #expect(CalculatorWidgetView.evaluate("x+1") == nil)        // unknown symbol → silent
        #expect(CalculatorWidgetView.evaluate(")(") == nil)         // unparseable → silent
    }

    /// The make-real substrate: a widget object inserts, its state edits, and undo reverts it in ONE step.
    @MainActor
    @Test func widgetInsertEditUndo() {
        let store = JournalStore()
        let id = UUID()
        let snap = ObjectSnapshot(objectID: id, kind: .widget,
                                  transform: Transform(width: 260, height: 380),
                                  pageID: store.pageID, createdBy: store.notebookID,
                                  payload: .widget(html: BlobRef(id: UUID(), kind: .widgetBundle, byteCount: 0),
                                                   jsState: "{\"display\":\"0\"}",
                                                   sandboxPolicy: "native:scientificCalculator"))
        store.perform([.addObject(snapshot: snap)])
        store.perform([.setObjectState(objectID: id, old: "{\"display\":\"0\"}", new: "{\"display\":\"42\"}")])
        if case .widget(_, let js, _)? = store.page.objects[id]?.payload {
            #expect(js == "{\"display\":\"42\"}")
        } else { Issue.record("expected a widget payload after insert+edit") }

        store.undo()   // one step
        if case .widget(_, let js, _)? = store.page.objects[id]?.payload {
            #expect(js == "{\"display\":\"0\"}")
        } else { Issue.record("expected widget to remain after undoing the edit") }
        #expect(store.page.objects[id] != nil)   // the widget itself is still there
    }

    // MARK: - Make-real consent gate (no Claude call until the session is eligible)

    @Test func makeRealConsentGate() {
        // The §5.1.2(i) AI permission must be granted before any "@" generation reaches the cloud.
        let blocked = MakeRealSession(isOnline: true, userKind: "adult", aiConsentGranted: false, ageVerified: true)
        #expect(blocked.blockReason != nil)
        let adult = MakeRealSession(isOnline: true, userKind: "adult", aiConsentGranted: true, ageVerified: true)
        #expect(adult.blockReason == nil)
        // Minors without verifiable parental consent are blocked even with the AI permission on (COPPA).
        let minor = MakeRealSession(isOnline: true, userKind: "minorUnconsented", aiConsentGranted: true, ageVerified: true)
        #expect(minor.blockReason != nil)
        let offline = MakeRealSession(isOnline: false, userKind: "adult", aiConsentGranted: true, ageVerified: true)
        #expect(offline.blockReason != nil)
        // Errors surface a human-readable reason (LocalizedError) rather than a generic message.
        #expect(MakeRealError.notConfigured("server down").errorDescription == "server down")
    }

    /// Editing a sticky's text updates it, and undo reverts it (one step).
    @MainActor
    @Test func stickyTextEditUndo() {
        let store = JournalStore()
        let id = UUID()
        let snap = ObjectSnapshot(objectID: id, kind: .sticky, transform: Transform(width: 160, height: 120),
                                  pageID: store.pageID, createdBy: store.notebookID,
                                  payload: .sticky(text: "Sticky", colorHex: "#FFE680"))
        store.perform([.addObject(snapshot: snap)])
        store.perform([.setProps(objectID: id, old: PropPatch(stickyText: "Sticky"), new: PropPatch(stickyText: "Buy milk"))])
        if case .sticky(let t, _)? = store.page.objects[id]?.payload { #expect(t == "Buy milk") } else { Issue.record("expected sticky") }
        store.undo()
        if case .sticky(let t, _)? = store.page.objects[id]?.payload { #expect(t == "Sticky") } else { Issue.record("expected sticky") }
    }

    /// Deleting an object removes it from the page, and undo restores it (one step).
    @MainActor
    @Test func objectDeleteUndo() {
        let store = JournalStore()
        let id = UUID()
        let snap = ObjectSnapshot(objectID: id, kind: .sticky, transform: Transform(width: 160, height: 120),
                                  pageID: store.pageID, createdBy: store.notebookID,
                                  payload: .sticky(text: "hi", colorHex: "#FFE680"))
        store.perform([.addObject(snapshot: snap)])
        #expect(store.page.objects[id]?.isDeleted == false)
        store.perform([.delete(objectID: id)])
        #expect(store.page.objects[id]?.isDeleted == true)    // removed from the page
        store.undo()
        #expect(store.page.objects[id]?.isDeleted == false)   // restored
    }

    /// Multi-page: back/forward is scoped to the page you're on; undo on one page never touches another.
    @MainActor
    @Test func perPageUndoIsolation() {
        let store = JournalStore()
        let p1 = store.pageID
        func add(_ id: UUID, _ text: String, on pageID: UUID) {
            let snap = ObjectSnapshot(objectID: id, kind: .sticky, transform: Transform(width: 160, height: 120),
                                      pageID: pageID, createdBy: store.notebookID, payload: .sticky(text: text, colorHex: "#FFE680"))
            store.perform([.addObject(snapshot: snap)])
        }
        let a = UUID(); add(a, "A", on: p1)
        let p2 = store.addPage(); store.goTo(p2)
        #expect(store.pageCount == 2)
        #expect(store.canUndo == false)            // page 2 starts with its own empty history
        let b = UUID(); add(b, "B", on: p2)
        #expect(store.canUndo)
        store.undo()                               // undoes B on page 2 only
        #expect(store.pageProjection(p2).objects[b]?.isDeleted ?? true)
        #expect(store.pageProjection(p1).objects[a]?.isDeleted == false)   // page 1 untouched
        store.goTo(p1)
        #expect(store.canUndo)                     // page 1 still has its own A to undo
        store.undo()
        #expect(store.pageProjection(p1).objects[a]?.isDeleted ?? true)
    }

    /// Persistence: the op log written to storage replays into the same projection on reload — objects
    /// and multiple pages survive, and new edits after reload still work (clock reseeded past the log).
    @MainActor
    @Test func journalPersistsAndReloads() {
        // In-memory storage that retains across JournalStore instances (stands in for the file store).
        final class Mem: JournalStorage {
            var ops: [Op] = []
            var ink: [UUID: Data] = [:]
            func loadOps() -> [Op] { ops }
            func append(_ newOps: [Op]) { ops.append(contentsOf: newOps) }
            func loadInk(page: UUID) -> Data? { ink[page] }
            func saveInk(_ data: Data, page: UUID) { ink[page] = data }
        }
        func sticky(_ id: UUID, on page: UUID, by notebook: UUID) -> OpPayload {
            .addObject(snapshot: ObjectSnapshot(objectID: id, kind: .sticky, transform: Transform(width: 160, height: 120),
                                                pageID: page, createdBy: notebook, payload: .sticky(text: "x", colorHex: "#FFE680")))
        }
        let storage = Mem()
        let notebook = UUID()
        let a = UUID(), b = UUID()
        // Session 1: a sticky on page 1, then a new page 2 with its own sticky.
        do {
            let store = JournalStore(notebookID: notebook, storage: storage)
            store.perform([sticky(a, on: store.pageID, by: store.notebookID)])
            let p2 = store.addPage(); store.goTo(p2)
            store.perform([sticky(b, on: p2, by: store.notebookID)])
            #expect(store.pageCount == 2)
            #expect(storage.ops.count >= 4)        // addPage(1) + A + addPage(2) + B persisted
        }
        // Session 2: reload from the same storage — everything comes back.
        let reloaded = JournalStore(notebookID: notebook, storage: storage)
        #expect(reloaded.pageCount == 2)
        let pages = reloaded.pageIDs
        #expect(reloaded.pageProjection(pages[0]).objects[a]?.isDeleted == false)   // page 1's sticky survived
        #expect(reloaded.pageProjection(pages[1]).objects[b]?.isDeleted == false)   // page 2's sticky survived
        // A new edit after reload still applies (the clock was advanced past the persisted ops).
        let c = UUID()
        reloaded.goTo(pages[0])
        reloaded.perform([sticky(c, on: reloaded.pageID, by: reloaded.notebookID)])
        #expect(reloaded.page.objects[c]?.isDeleted == false)
    }

    /// A read failure is not an empty notebook. The store exposes a temporary in-memory page for the UI,
    /// surfaces the error, and refuses to append fresh operations into the unreadable journal.
    @MainActor
    @Test func unreadableJournalIsNeverReseeded() {
        enum Failure: Error { case unreadable }
        final class Broken: JournalStorage {
            var appendAttempts = 0
            func loadOps() throws -> [Op] { throw Failure.unreadable }
            func append(_ newOps: [Op]) throws { appendAttempts += 1 }
            func loadInk(page: UUID) -> Data? { nil }
            func saveInk(_ data: Data, page: UUID) {}
        }

        let storage = Broken()
        let store = JournalStore(notebookID: UUID(), storage: storage)
        #expect(!store.isPersistenceAvailable)
        #expect(store.pageCount == 1)          // temporary UI page, not persisted
        #expect(storage.appendAttempts == 0)  // init did not seed over the failed read

        var surfaced = false
        store.onPersistenceError = { _ in surfaced = true }
        #expect(surfaced)                     // late UI wiring still receives the load failure
        store.perform([])
        #expect(storage.appendAttempts == 0)  // subsequent edits remain in-memory only
    }

    /// A failed first append must be remembered even though the UI callback is wired after store init.
    /// Later writes stop at the gap instead of producing a journal that references an unpersisted page.
    @MainActor
    @Test func initialAppendFailureBlocksLaterWritesAndSurfacesLate() {
        enum Failure: Error { case fullDisk }
        final class Broken: JournalStorage {
            var appendAttempts = 0
            func loadOps() -> [Op] { [] }
            func append(_ newOps: [Op]) throws { appendAttempts += 1; throw Failure.fullDisk }
            func loadInk(page: UUID) -> Data? { nil }
            func saveInk(_ data: Data, page: UUID) {}
        }

        let storage = Broken()
        let store = JournalStore(notebookID: UUID(), storage: storage)
        #expect(storage.appendAttempts == 1)       // failed while persisting the initial page
        #expect(!store.isPersistenceAvailable)

        var surfaced = false
        store.onPersistenceError = { _ in surfaced = true }
        #expect(surfaced)                          // late UI wiring still gets the first failure
        store.perform([])
        #expect(storage.appendAttempts == 1)       // never leapfrog the missing initial operation
    }

    /// Only a non-newline-terminated final record is a crash tail. Repair it before future appends;
    /// a complete but undecodable final record is real corruption and must stop the notebook loading.
    @MainActor
    @Test func opLogRepairsTornTailButRejectsCompleteCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = UUID()
        let storage = FileJournalStorage(notebookID: notebook, root: root)
        let logURL = FileJournalStorage.notebookDir(notebook, root: root)
            .appendingPathComponent("oplog.jsonl")

        try Data("{\"torn\":".utf8).write(to: logURL)
        #expect(try storage.loadOps().isEmpty)
        #expect(try Data(contentsOf: logURL).isEmpty)       // repaired, so the next append starts cleanly

        _ = JournalStore(notebookID: notebook, storage: storage) // writes one complete initial-page op
        let terminated = try Data(contentsOf: logURL)
        #expect(terminated.last == 0x0A)
        try Data(terminated.dropLast()).write(to: logURL)   // JSON complete; only delimiter was torn
        #expect(try storage.loadOps().count == 1)
        #expect(try Data(contentsOf: logURL).last == 0x0A)   // repaired without dropping the valid op

        try Data("{\"complete\":false}\n".utf8).write(to: logURL)
        #expect(throws: JournalStorageError.self) { try storage.loadOps() }
    }

    /// An operation targeting a background page owns that page's undo stack even while another page is
    /// visible. This is the JournalStore half of async recognition/generation page ownership.
    @MainActor
    @Test func offscreenTransactionKeepsOffscreenUndoOwnership() {
        let store = JournalStore()
        let first = store.pageID
        let second = store.addPage()
        let id = UUID()
        let snap = ObjectSnapshot(objectID: id, kind: .sticky, transform: Transform(width: 160, height: 120),
                                  pageID: second, createdBy: store.notebookID,
                                  payload: .sticky(text: "async", colorHex: "#FFE680"))
        store.goTo(first)
        store.perform([.addObject(snapshot: snap)], onPage: second)
        #expect(!store.canUndo)                // page 1 history was not polluted
        store.goTo(second)
        #expect(store.canUndo)
        store.undo()
        #expect(store.page.objects[id]?.isDeleted ?? true)
    }

    /// Relaunching reopens the page the user was last on (not always page 1), so work on a later page
    /// isn't perceived as lost. The op log keeps page identity stable; the last-viewed page is UI state.
    @MainActor
    @Test func reloadReopensLastViewedPage() {
        final class Mem: JournalStorage {
            var ops: [Op] = []
            func loadOps() -> [Op] { ops }
            func append(_ newOps: [Op]) { ops.append(contentsOf: newOps) }
            func loadInk(page: UUID) -> Data? { nil }
            func saveInk(_ data: Data, page: UUID) {}
        }
        let storage = Mem(); let notebook = UUID()
        let secondPage: UUID
        do {
            let store = JournalStore(notebookID: notebook, storage: storage)
            secondPage = store.addPage()
            store.goTo(secondPage)                       // user navigates to page 2 → remembered
        }
        let reloaded = JournalStore(notebookID: notebook, storage: storage)
        #expect(reloaded.pageCount == 2)
        #expect(reloaded.pageID == secondPage)           // reopened on page 2, not page 1
        UserDefaults.standard.removeObject(forKey: "inklab.currentPage.\(notebook.uuidString)")  // cleanup
    }

    /// Bring a hand-drawn graph to life: a sketched parabola fits as Quadratic with near-perfect R²,
    /// and a straight sketch fits as Linear — deterministically (InkLabFit), correct by construction.
    @MainActor
    @Test func curveFitterClassifiesSketchShape() {
        // A clean parabola y = x² sampled across x ∈ [-3, 3].
        let parabola = stride(from: -3.0, through: 3.0, by: 0.3).map { Point2D(x: $0, y: $0 * $0) }
        let pFit = CurveFitter.fit(parabola)
        #expect(pFit?.model == "Quadratic")
        #expect((pFit?.rSquared ?? 0) > 0.98)

        // A straight line y = 2x + 1.
        let line = stride(from: 0.0, through: 6.0, by: 0.3).map { Point2D(x: $0, y: 2 * $0 + 1) }
        let lFit = CurveFitter.fit(line)
        #expect(lFit?.model == "Linear")
        #expect((lFit?.rSquared ?? 0) > 0.99)
        #expect(lFit?.equation.hasPrefix("y = ") == true)
    }

    /// Handwrite → plot: a recognized "y = …" / "f(x) = …" is trimmed to the bare expression a grapher
    /// wants; a plain expression is passed through unchanged.
    @MainActor
    @Test func plottableExpressionStripsLeadingAssignment() {
        #expect(CanvasViewController.plottableExpression("y = x^2 - 3") == "x^2 - 3")
        #expect(CanvasViewController.plottableExpression("f(x) = sin(x)") == "sin(x)")
        #expect(CanvasViewController.plottableExpression("2x + 1") == "2x + 1")
    }

    /// A persisted undo's EFFECT survives reload (its inverse op is on disk), but the undo HISTORY is
    /// session-only by design — so after relaunch you can't redo a prior session's undo.
    @MainActor
    @Test func persistedUndoSurvivesReloadHistoryResets() {
        final class Mem: JournalStorage {
            var ops: [Op] = []
            func loadOps() -> [Op] { ops }
            func append(_ newOps: [Op]) { ops.append(contentsOf: newOps) }
            func loadInk(page: UUID) -> Data? { nil }
            func saveInk(_ data: Data, page: UUID) {}
        }
        let storage = Mem(); let notebook = UUID(); let a = UUID()
        do {
            let store = JournalStore(notebookID: notebook, storage: storage)
            store.perform([.addObject(snapshot: ObjectSnapshot(objectID: a, kind: .sticky, transform: Transform(width: 160, height: 120),
                                                               pageID: store.pageID, createdBy: store.notebookID, payload: .sticky(text: "x", colorHex: "#FFE680")))])
            store.undo()                                    // removes A; the inverse op is persisted
            #expect(store.page.objects[a]?.isDeleted ?? true)
        }
        let reloaded = JournalStore(notebookID: notebook, storage: storage)
        #expect(reloaded.page.objects[a]?.isDeleted ?? true)   // undo EFFECT persisted (A still gone)
        #expect(reloaded.canUndo == false)                     // undo HISTORY resets — session-only by design
    }

    // MARK: - On-device Apple Vision recognizer

    @MainActor
    @Test func visionReadsRenderedText() async throws {
        let raster = Self.renderText("2x + 3 = 7")
        let input = RecognitionInput(
            strokes: [],
            raster: raster,
            region: Rect(x: 0, y: 0, width: 600, height: 160),
            domainHint: .math,
            session: SessionContext(isOnline: false, userKind: .adult, cloudAIConsentGranted: false)
        )
        let result = try await VisionTextRecognizer().recognize(input)
        #expect(result.provider == .appleVision)
        #expect(result.isOnDevice)
        if case .plainText(let text) = result.formal {
            #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(text.contains("7"))   // clean rendered digits read reliably
        } else {
            Issue.record("expected .plainText, got \(result.formal)")
        }
    }

    /// DIAGNOSTIC: does Apple Vision actually output the "@" glyph + the words from legible text?
    @MainActor
    @Test func visionReadsAtCommand() async throws {
        for s in ["@a clock", "@balance H2 + O2 -> H2O", "@scientific calculator", "@a pendulum"] {
            let raster = Self.renderText(s)
            let r = try await VisionTextRecognizer().recognize(
                RecognitionInput(strokes: [], raster: raster,
                                 region: Rect(x: 0, y: 0, width: 700, height: 160),
                                 domainHint: .text,
                                 session: SessionContext(isOnline: false, userKind: .adult, cloudAIConsentGranted: false)))
            let read = r.readAs.trimmingCharacters(in: .whitespaces)
            // Surface the actual reading via the failure message (print() doesn't reach the build log).
            #expect(read.hasPrefix("@"), Comment(rawValue: "VISION_READ[\(s)] => «\(r.readAs)»"))
        }
    }

    @MainActor
    private static func renderText(_ s: String) -> RasterImage {
        let size = CGSize(width: 600, height: 160)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            (s as NSString).draw(at: CGPoint(x: 20, y: 30),
                                 withAttributes: [.font: UIFont.systemFont(ofSize: 80),
                                                  .foregroundColor: UIColor.black])
        }
        return RasterImage(pngData: image.pngData()!,
                           width: Int(size.width * 2), height: Int(size.height * 2))
    }

    // MARK: - Undo resurrection guard (stale-render defense)

    /// A deterministic single stroke whose byte-signature is keyed off `x`, so two strokes built with the
    /// same `x` serialize identically (simulating PencilKit re-introducing the *same* stroke), while
    /// different `x` values are distinct (a genuinely new stroke).
    private static func stroke(_ x: CGFloat) -> PKStroke {
        let pts = (0..<5).map { i in
            PKStrokePoint(location: CGPoint(x: x + CGFloat(i), y: 10), timeOffset: TimeInterval(i) * 0.01,
                          size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSinceReferenceDate: Double(x)))
        return PKStroke(ink: PKInk(.pen, color: .black), path: path)
    }

    /// The reported bug + the cases that broke a naïve suffix/count reconciliation. When PencilKit's async
    /// `.drawing` swap lets a removed stroke reappear, the delegate strips it by EXACT signature — so the
    /// undone ink can't return, while a legitimate eraser edit (which also grows the stroke count, but with
    /// new signatures) is left untouched.
    @MainActor
    @Test func resurrectedStrokesAreStrippedByIdentity() {
        let sig = CanvasViewController.strokeSignature
        let strip = CanvasViewController.strippingResurrectedStrokes
        let mk = Self.stroke

        // The whole defense rests on a stroke's signature being STABLE for identical content (so a
        // resurrected stroke matches the signature we captured when it was removed). Assert it directly.
        #expect(sig(mk(7)) == sig(mk(7)))   // same content → same signature
        #expect(sig(mk(7)) != sig(mk(8)))   // different content → different signature
        #expect(CanvasViewController.drawingsHaveSameContent(PKDrawing(strokes: [mk(7)]),
                                                             PKDrawing(strokes: [mk(7)])))
        #expect(!CanvasViewController.drawingsHaveSameContent(PKDrawing(strokes: [mk(7)]),
                                                              PKDrawing(strokes: [mk(8)])))

        // PRIMARY (the user's report): write A, undo (baseline empty), rewrite B; PencilKit resurrects A
        // onto the stale drawing → live = [A, B]. A must be dropped, B kept.
        let a = mk(0), b = mk(100)
        let primary = strip([a, b], 0, [sig(a)])
        #expect(primary.stripped)
        #expect(primary.kept.count == 1)
        #expect(sig(primary.kept[0]) == sig(b))

        // INTERIOR/TAIL: this is where suffix-slicing failed — the resurrected stroke sits at the TAIL next
        // to the new one. baseline = [S0,S1], undo removed S2, rewrite → live = [S0,S1,S2,new].
        let s0 = mk(0), s1 = mk(50), s2 = mk(100), new = mk(150)
        let interior = strip([s0, s1, s2, new], 2, [sig(s2)])
        #expect(interior.stripped)
        #expect(interior.kept.count == 3)
        #expect(!interior.kept.contains { sig($0) == sig(s2) })   // S2 gone
        #expect(interior.kept.contains { sig($0) == sig(new) })   // genuine new stroke kept

        // ERASER growth: a bitmap eraser splitting a stroke RAISES the count, but its fragments carry NEW
        // signatures that match nothing in `removed` — so nothing is stripped (no corruption of the erase).
        let eraser = strip([s0, s1, s2, new], 3, [sig(mk(999))])
        #expect(!eraser.stripped)
        #expect(eraser.kept.count == 4)

        // CLEAN append (guard disarmed): empty `removed` → never strips.
        #expect(!strip([a, b], 0, []).stripped)

        // NO GROWTH: a removed stroke present without the drawing growing is not a resurrection-add, so the
        // guard leaves it alone (only a count increase can be a stale-render resurrection).
        #expect(!strip([a, b], 2, [sig(a)]).stripped)
    }

    // MARK: - Generated widget HTML (stray model text, CSP placement, title, card sizes)

    private static let widgetDoc = """
    <!DOCTYPE html>
    <html lang="en"><head><meta name="inklab-layout" content="square"><title>Pendulum &amp; Spring</title></head>
    <body><svg><title>bob</title></svg><button>Go</button></body></html>
    """

    @Test func widgetHTMLStripsPreambleFencesAndMarker() {
        let raw = "I'll build a pendulum.\n\n```html\n\(Self.widgetDoc)\n```\n<!-- INKLAB_DONE -->"
        #expect(WidgetHTML.extractDocument(raw) == Self.widgetDoc)
        #expect(WidgetHTML.extractDocument(Self.widgetDoc) == Self.widgetDoc)              // clean → unchanged
        #expect(WidgetHTML.extractDocument("Here:\n```html\n<div>x</div>\n```") == "<div>x</div>")
    }

    @Test func sandboxedDocumentPutsCSPFirstInStandardsMode() {
        let fenced = "Sure!\n```html\n\(Self.widgetDoc)\n```"
        let doc = WidgetHTML.sandboxedDocument(fenced)
        #expect(doc.hasPrefix("<!doctype html><meta http-equiv=\"Content-Security-Policy\""))   // nothing ahead of the CSP
        #expect(!doc.contains("Sure!"))
        #expect(!doc.contains("```"))
        #expect(doc.contains("<html lang=\"en\">"))                                        // widget markup kept
        // A document with a decorated <head …> (or none at all) still gets the CSP — and a doctype.
        let noDoctype = WidgetHTML.sandboxedDocument("<html><head lang=\"en\"><script>1</script></head></html>")
        #expect(noDoctype.hasPrefix("<!doctype html><meta http-equiv=\"Content-Security-Policy\""))
        // A body fragment is wrapped in our own CSP'd document.
        let fragment = WidgetHTML.sandboxedDocument("<div>hi</div>")
        #expect(fragment.contains("Content-Security-Policy"))
        #expect(fragment.contains("<body><div>hi</div></body>"))
    }

    @Test func widgetTitleComesFromTheHeadOnly() {
        #expect(WidgetHTML.title(in: Self.widgetDoc) == "Pendulum & Spring")
        #expect(WidgetHTML.title(in: "<html><body><svg><title>bob</title></svg></body></html>") == nil)
        #expect(WidgetHTML.title(in: "<head><title>   </title></head>") == nil)
    }

    @Test func widgetCardSizesLeaveTheContentAreaIntact() {
        #expect(WidgetLayout.portrait.contentSize == CGSize(width: 360, height: 540))
        #expect(WidgetLayout(rawValue: "landscape")?.contentSize == CGSize(width: 560, height: 360))
        let card = WidgetCard.size(content: WidgetLayout.square.contentSize)
        #expect(card.height - WidgetCard.headerHeight - WidgetCard.footerHeight == 440)
        // Native widgets keep their content size now that the resize grip has its own footer bar.
        let calc = NativeWidgetRegistry.defaultSize(kind: "scientificCalculator")
        #expect(calc.height - WidgetCard.headerHeight - WidgetCard.footerHeight == 352)
    }

    @Test func makeRealErrorsSayWhatHappened() {
        // A timeout is not "start the server".
        #expect(ProxyMakeRealProvider.message(for: URLError(.timedOut)) == ProxyMakeRealProvider.tooSlow)
        #expect(ProxyMakeRealProvider.message(for: URLError(.cannotConnectToHost)) == ProxyMakeRealProvider.unreachable)
        #expect(ProxyMakeRealProvider.message(for: URLError(.notConnectedToInternet)).contains("offline"))
        #expect(ProxyMakeRealProvider.message(status: 504, error: "generation timed out") == ProxyMakeRealProvider.tooSlow)
        #expect(ProxyMakeRealProvider.message(status: 422, error: "declined").contains("declined"))
        #expect(ProxyMakeRealProvider.message(status: 403, error: "offline") == "offline")   // consent reasons pass through
        #expect(ProxyMakeRealProvider.message(status: 500, error: nil) == "Generator error (status 500).")
        // The client waits longer than the proxy's 170 s whole-request deadline.
        #expect(ProxyMakeRealProvider.requestTimeout > 170)
    }

    /// End-to-end in real WebKit: a fenced, prose-wrapped reply renders as a standards-mode page with no
    /// stray text, the widget's own <html> attributes and <title> survive, and the CSP is already in force
    /// when the widget's FIRST script runs (an early synchronous network call is refused by policy).
    @MainActor
    @Test func sandboxedWidgetLoadsCleanlyInWebKit() async throws {
        let reply = """
        Sure! Here's your widget.

        ```html
        <!DOCTYPE html>
        <html lang="en" data-widget="probe"><head><title>Probe</title>
        <script>
          window.violations = 0;
          document.addEventListener('securitypolicyviolation', function () { window.violations++; });
          window.early = (function () {
            try { var x = new XMLHttpRequest(); x.open('GET', 'https://example.com/', false); x.send(); return 'allowed'; }
            catch (e) { return 'blocked'; }
          })();
        </script></head><body><p>widget body</p></body></html>
        ```
        <!-- INKLAB_DONE -->
        """
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 540))
        let waiter = NavigationWaiter()
        web.navigationDelegate = waiter
        web.loadHTMLString(WidgetHTML.sandboxedDocument(reply), baseURL: nil)
        try await waiter.finished()
        try await Task.sleep(for: .milliseconds(300))   // let the queued violation event dispatch

        #expect(try await web.evaluateJavaScript("document.compatMode") as? String == "CSS1Compat")
        #expect(try await web.evaluateJavaScript("document.body.innerText.trim()") as? String == "widget body")
        #expect(try await web.evaluateJavaScript("document.title") as? String == "Probe")
        #expect(try await web.evaluateJavaScript("document.documentElement.getAttribute('data-widget')") as? String == "probe")
        #expect(try await web.evaluateJavaScript(
            "document.head.firstElementChild.getAttribute('http-equiv')") as? String == "Content-Security-Policy")
        #expect(try await web.evaluateJavaScript("window.early") as? String == "blocked")
        #expect((try await web.evaluateJavaScript("window.violations") as? Int ?? 0) >= 1)   // blocked BY the CSP
    }
}

/// Render check (hidden test render before a generated widget is placed): catches the failures that used to
/// show a blank card. Real WebKit, same lockdown as the live renderer.
struct WidgetRenderCheckTests {
    private let size = CGSize(width: 360, height: 540)

    @MainActor
    @Test func catchesAScriptThatDoesNotParse() async {
        // The real failure seen in testing: an apostrophe inside a single-quoted string kills the whole script.
        let html = "<!DOCTYPE html><html><body><canvas id='c'></canvas><script>var label = 'the cell's nucleus'; draw();</script></body></html>"
        let health = await WidgetRenderCheck.run(html: html, size: size, settle: .milliseconds(300))
        #expect(!health.ok)
        #expect(health.problem.contains("SyntaxError"))
    }

    @MainActor
    @Test func catchesACrashInsideTheAnimationLoop() async {
        // Off-screen there are no animation frames; the probe drives them so draw-loop errors still surface.
        let html = "<!DOCTYPE html><html><body><p>Orbit</p><script>var n=0;function frame(){n++; if(n===3){ undefinedPlanet.move(); } requestAnimationFrame(frame);} requestAnimationFrame(frame);</script></body></html>"
        let health = await WidgetRenderCheck.run(html: html, size: size, settle: .milliseconds(800))
        #expect(!health.ok)
        #expect(health.problem.contains("undefinedPlanet"))
    }

    @MainActor
    @Test func passesAHealthyWidgetAndFlagsAnEmptyOne() async {
        let good = "<!DOCTYPE html><html><body><canvas id='c' width='100' height='100'></canvas><script>var x=document.getElementById('c').getContext('2d'); function f(){x.fillRect(0,0,10,10); requestAnimationFrame(f);} requestAnimationFrame(f);</script></body></html>"
        #expect(await WidgetRenderCheck.run(html: good, size: size, settle: .milliseconds(300)).ok)
        let empty = await WidgetRenderCheck.run(html: "<!DOCTYPE html><html><body><div></div></body></html>", size: size, settle: .milliseconds(300))
        #expect(!empty.ok)
        #expect(empty.problem == "the widget showed nothing")
    }

    @Test func retryPromptCarriesTheErrorAndStaysUnderTheCap() {
        let health = RenderHealth(errors: ["SyntaxError: Unexpected identifier 's' (line 40)"], visible: true)
        let retry = makeRealRetryPrompt("animated cell", after: health)
        #expect(retry.hasPrefix("animated cell"))
        #expect(retry.contains("SyntaxError: Unexpected identifier 's'"))
        #expect(makeRealRetryPrompt(String(repeating: "x", count: 5000), after: health).count < 2000)
    }

    @Test func probeRunsBeforeAnyWidgetScript() {
        let doc = WidgetHTML.sandboxedDocument("<!DOCTYPE html><html><head><script>1</script></head></html>",
                                               extraHead: WidgetRenderCheck.probeScript)
        let csp = doc.range(of: "Content-Security-Policy")!.lowerBound
        let probe = doc.range(of: "__inklabRenderErrors")!.lowerBound
        let widget = doc.range(of: "<script>1</script>")!.lowerBound
        #expect(csp < probe && probe < widget)
    }
}

/// Awaits a WKWebView's first navigation.
@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func finished() async throws {
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    private func complete(_ r: Result<Void, Error>) {
        guard result == nil else { return }
        result = r
        continuation?.resume(with: r)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { complete(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { complete(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        complete(.failure(error))
    }
}
