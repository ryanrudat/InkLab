import Testing
import Foundation
import UIKit
import InkLabKit
@testable import InkLab

/// The Socratic tutor on the app side: the engine decides (verdict, protected answer, every step the
/// student writes back), the proxy talks, and nothing that gives the answer away reaches the page.
@MainActor
struct TutorTests {

    private let problem = CGRect(x: 40, y: 80, width: 220, height: 140)

    private func session(_ read: String) -> TutorSession {
        guard case .success(let s) = TutorSession.start(read: read, problem: problem) else {
            Issue.record("expected a session for \(read)")
            return TutorSession(problem: problem, pageLines: ["x"], lineRects: [problem], anchorLine: 1, lines: ["x"])
        }
        return s
    }

    /// A scripted proxy: replies in order, and remembers every request.
    final class FakeProvider: TutorProvider, @unchecked Sendable {
        var replies: [String]
        var requests: [TutorRequest] = []
        init(_ replies: [String]) { self.replies = replies }
        func reply(to request: TutorRequest) async throws -> TutorReply {
            requests.append(request)
            let text = replies.isEmpty ? "?" : replies.removeFirst()
            return TutorReply(reply: text, rung: 1, guardOutcome: "clean")
        }
    }

    // MARK: READ → COMPUTE

    @Test func startRunsTheRedPenAndProtectsTheAnswer() throws {
        let s = session("2x + 3 = 7\n2x = 10\nx = 5")
        #expect(s.lines == ["2x + 3 = 7", "2x = 10", "x = 5"])
        guard case .firstError(let line, _, _, _) = s.verdict else { Issue.record("expected the red pen to flag a line"); return }
        #expect(line == 2)

        let req = s.request(session: MakeRealSession(isOnline: true, userKind: "adult", aiConsentGranted: true, ageVerified: true))
        #expect(req.chain == "equation")
        #expect(req.verdict.kind == "firstError" && req.verdict.line == 2)
        #expect(req.protected.count == 1 && req.protected[0].kind == "equation")
        #expect(req.thread.isEmpty && req.strict == false)

        // Wire shape the proxy validates: optional fields are omitted, the reply's `guard` key decodes.
        let json = try #require(String(data: JSONEncoder().encode(req), encoding: .utf8))
        #expect(json.contains("\"lines\"") && json.contains("\"protected\"") && !json.contains("\"steps\""))
        let reply = try JSONDecoder().decode(TutorReply.self, from: Data(#"{"reply":"Look at line 2.","rung":2,"guard":"regenerated"}"#.utf8))
        #expect(reply == TutorReply(reply: "Look at line 2.", rung: 2, guardOutcome: "regenerated"))
    }

    @Test func calculusProblemsProtectTheEnginesResult() {
        let d = session("d/dx(x^3 + 2x) = 3x^2")
        #expect(d.request(session: .init(isOnline: true, userKind: "adult", aiConsentGranted: true, ageVerified: true)).chain == "derivative")
        #expect(TutorGuard.leak(in: "It's 2 + 3x^2.", session: d) != nil)
        let i = session("∫ x^2 dx = x^3/2 + C")
        #expect(TutorGuard.leak(in: "Try x³/3 + C.", session: i) != nil)
    }

    @Test func nothingReadableStartsNothing() {
        #expect(TutorSession.start(read: "  \n ", problem: problem) == .failure(.nothingRead))
        #expect(TutorSession.start(read: String(repeating: "x+1\n", count: 40), problem: problem) == .failure(.tooLong))
    }

    // MARK: Every step the student writes back is checked by the engine, not the model

    @Test func aCorrectedStepIsVerifiedAndReplacesTheWrongLine() {
        let s = session("2x + 3 = 7\n2x = 10\nx = 5")
        let fixed = s.addingStudentReply("2x = 4", wantsHint: false)
        #expect(fixed.thread.last?.check == .follows)
        #expect(fixed.lines == ["2x + 3 = 7", "2x = 4"])
        if case .allValid = fixed.verdict {} else { Issue.record("the corrected working should check out") }
        // The tutor is told what changed: line 2 corrected, the line after it dropped. The page lines stay.
        #expect(fixed.corrections == [TutorCorrection(line: 2, from: ["2x = 10", "x = 5"], to: ["2x = 4"])])
        #expect(fixed.pageLines == s.pageLines)
        let req = fixed.request(session: .init(isOnline: true, userKind: "adult", aiConsentGranted: true, ageVerified: true))
        #expect(req.lines == ["2x + 3 = 7", "2x = 10", "x = 5"] && req.working == ["2x + 3 = 7", "2x = 4"])
        #expect(req.verdict.kind == "allValid" && req.corrections.count == 1)

        let stillWrong = s.addingStudentReply("2x = 3", wantsHint: false)
        #expect(stillWrong.thread.last?.check == .doesNotFollow)
        #expect(stillWrong.lines == s.lines)

        // Prose is a message, not a step; an equation inside a sentence is a step.
        #expect(s.addingStudentReply("I subtracted 3 from both sides", wantsHint: false).thread.last?.check == nil)
        // A question is checked, but never folded into the working (the live "so is x = 2?" bug).
        let asked = s.addingStudentReply("is it 2x = 4?", wantsHint: false)
        #expect(asked.thread.last?.check == .follows && asked.thread.last?.question == true)
        #expect(asked.lines == s.lines && asked.corrections.isEmpty)
        let afterFix = fixed.addingStudentReply("so is x = 2?", wantsHint: false)
        #expect(afterFix.thread.last?.check == .follows)
        #expect(afterFix.lines == fixed.lines && afterFix.corrections == fixed.corrections)
        #expect(TutorSession.isQuestion("what do I do next") && !TutorSession.isQuestion("2x = 4"))
        // Asking for a hint is never graded.
        let hint = s.addingStudentReply("", wantsHint: true)
        #expect(hint.thread.last?.wantsHint == true && hint.thread.last?.check == nil)
    }

    @Test func aOneLineCalculusClaimIsCorrectedWithJustTheResult() {
        let s = session("d/dx(x^2) = x")
        let fixed = s.addingStudentReply("2x", wantsHint: false)
        #expect(fixed.thread.last?.check == .follows)
        #expect(fixed.lines == ["d/dx(x^2) = 2x"])
        #expect(fixed.corrections == [TutorCorrection(line: 1, from: ["d/dx(x^2) = x"], to: ["d/dx(x^2) = 2x"])])
    }

    @Test func theStudentsOwnStepsMayBeQuotedBack() {
        let s = session("2x + 3 = 7\n2x = 10").addingStudentReply("2x = 4", wantsHint: false)
        #expect(TutorGuard.leak(in: "Yes! 2x = 4 checks out. What's next?", session: s) == nil)
        #expect(TutorGuard.leak(in: "Yes! So x = 2.", session: s) != nil)
    }

    // MARK: TALK — the app's own leak check, after the proxy's

    @Test func aLeakingReplyIsRegeneratedStrictly() async throws {
        let s = session("2x + 3 = 7\n2x = 10")
        let fake = FakeProvider(["Subtract 3 and you get 2x = 4.", "What did you do to both sides to get line 2?"])
        let consent = MakeRealSession(isOnline: true, userKind: "adult", aiConsentGranted: true, ageVerified: true)
        let reply = try await Tutor.nextMessage(for: s, consent: consent, provider: fake)
        #expect(reply.reply == "What did you do to both sides to get line 2?")
        #expect(fake.requests.map(\.strict) == [false, true])
    }

    @Test func aReplyThatKeepsLeakingBecomesAGenericHint() async throws {
        let s = session("2x + 3 = 7\n2x = 10")
        let fake = FakeProvider(["x = 2", "The answer is x is 2"])
        let reply = try await Tutor.nextMessage(for: s, consent: .init(isOnline: true, userKind: "adult", aiConsentGranted: true, ageVerified: true), provider: fake)
        #expect(reply.guardOutcome == "fallback")
        #expect(TutorGuard.leak(in: reply.reply, session: s) == nil)
        #expect(!reply.reply.contains("x = 2"))
    }

    @Test func theTutorNeedsTheAIPermission() {
        #expect(MakeRealSession(isOnline: true, userKind: "adult", aiConsentGranted: false, ageVerified: true).tutorBlockReason != nil)
        #expect(MakeRealSession(isOnline: true, userKind: "minorUnconsented", aiConsentGranted: true, ageVerified: true).tutorBlockReason != nil)
        #expect(MakeRealSession(isOnline: true, userKind: "adult", aiConsentGranted: true, ageVerified: true).tutorBlockReason == nil)
    }

    // MARK: The margin note

    /// Three written lines (the strokes' bounds), as on a page.
    private let rows = [CGRect(x: 50, y: 100, width: 180, height: 20), CGRect(x: 50, y: 150, width: 120, height: 22),
                        CGRect(x: 52, y: 200, width: 90, height: 18)]

    @Test func eachLineOfInkIsFoundSoTheNoteCanPointAtIt() {
        let problem = CGRect(x: 40, y: 90, width: 210, height: 140)
        // Two strokes on one line (e.g. "2x" and "= 10") merge into one row.
        let strokes = rows + [CGRect(x: 120, y: 152, width: 40, height: 16)]
        #expect(TutorLayout.lineRects(strokes: strokes, problem: problem, count: 3).map(\.minY) == [100, 150, 200])
        // Ink that doesn't split into one row per transcribed line: even bands instead.
        #expect(TutorLayout.lineRects(strokes: [rows[0]], problem: problem, count: 2).count == 2)

        // The note points at the line the verdict is about (line 2 here).
        guard case .success(let s) = TutorSession.start(read: "2x + 3 = 7\n2x = 10\nx = 5", problem: problem, strokes: rows) else {
            Issue.record("no session"); return
        }
        #expect(s.anchorLine == 2 && s.anchorRect == rows[1])
    }

    @Test func theNoteSitsInTheMarginAndNeverCoversInk() {
        let problem = CGRect(x: 40, y: 90, width: 210, height: 140)
        let size = CGSize(width: 280, height: 120)
        let frame = TutorLayout.marginFrame(size: size, anchor: rows[1], problem: problem, ink: rows, canvasWidth: 820)
        #expect(frame.minX > problem.maxX && abs(frame.minY - (rows[1].midY - 22)) < 0.5)
        #expect(!rows.contains { $0.intersects(frame) })

        // Other writing to the right of the problem pushes the note further out.
        let other = CGRect(x: 300, y: 140, width: 120, height: 30)
        let pushed = TutorLayout.marginFrame(size: size, anchor: rows[1], problem: problem, ink: rows + [other], canvasWidth: 820)
        #expect(pushed.minX > other.maxX && !(rows + [other]).contains { $0.intersects(pushed) })

        // No room in the margin: under the ink, still covering nothing.
        let wall = CGRect(x: 280, y: 0, width: 520, height: 600)
        let below = TutorLayout.marginFrame(size: size, anchor: rows[1], problem: problem, ink: rows + [wall], canvasWidth: 820)
        #expect(!(rows + [wall]).contains { $0.intersects(below) } && below.minY > problem.maxY)
    }

    @Test func onlyTheLatestMessageShowsTheRestFoldsIntoEarlier() throws {
        var s = session("2x + 3 = 7\n2x = 10\nx = 5")
        s.thread.append(TutorTurn(role: .tutor, text: "Look at line 2: what did you do?"))
        let first = TutorNoteView.height(for: TutorCalloutProvenance(tutor: s, turn: 1))
        s = s.addingStudentReply("2x = 4", wantsHint: false)
        s.thread.append(TutorTurn(role: .tutor, text: "Nice fix to line 2. What comes next?"))

        let note = TutorNoteView(frame: CGRect(x: 0, y: 0, width: 280, height: 10))
        note.configure(TutorCalloutProvenance(tutor: s, turn: 2))
        let collapsed = note.fittingHeight(width: 280)
        func label(_ id: String) -> UILabel? { note.subviews.first { $0.accessibilityIdentifier == id } as? UILabel }
        #expect(label("tutorMessage")?.text == "Nice fix to line 2. What comes next?")
        let earlier = try #require(note.subviews.first { $0.accessibilityIdentifier == "tutorEarlier" } as? UIButton)
        #expect(earlier.configuration?.title == "2 earlier")

        // Expanding shows the thread — the student's reply with the engine's check — and grows the note.
        earlier.sendActions(for: .touchUpInside)
        #expect(note.isExpanded && note.fittingHeight(width: 280) > collapsed)
        let rows = note.subviews.compactMap { $0 as? UILabel }.filter { $0.accessibilityIdentifier == "tutorThread" && !$0.isHidden }
        #expect(rows.contains { $0.attributedText?.string == "You: 2x = 4  ✓ checks out" })
        #expect(collapsed >= first)   // one control taller than the first message's note, not one card per message
    }

    /// The journal is the source of truth: a session is ONE note object; each message replaces its payload
    /// (one undo step), so undo rewinds the conversation a message at a time and closing removes it.
    @Test func theConversationLivesInTheJournalAndUndoRewindsIt() {
        let store = JournalStore()
        var s = session("2x + 3 = 7\n2x = 10")
        s.thread.append(TutorTurn(role: .tutor, text: "Look at line 2."))
        let id = UUID()
        func payload(_ s: TutorSession, _ turn: Int) -> ObjectPayload {
            .callout(text: s.thread.last?.text ?? "", sourceObjectIDs: [], provenanceJSON: TutorCalloutProvenance(tutor: s, turn: turn).json)
        }
        let first = payload(s, 1)
        let snap = ObjectSnapshot(objectID: id, kind: .callout, transform: Transform(x: 300, y: 80, width: 280, height: 100),
                                  pageID: store.pageID, createdBy: store.notebookID, payload: first)
        store.perform([.aiInsert(snapshot: snap, provenanceJSON: "{}")])
        s = s.addingStudentReply("I'm stuck", wantsHint: false)
        s.thread.append(TutorTurn(role: .tutor, text: "What did you do to both sides?"))
        store.perform([.promote(objectID: id, old: first, new: payload(s, 2)),
                       .setTransform(objectID: id, old: snap.transform, new: Transform(x: 300, y: 80, width: 280, height: 140))])

        var sessions = TutorLayout.sessions(on: store.page)
        #expect(sessions.count == 1 && sessions[0].all.count == 1)
        #expect(sessions[0].latest.provenance.turn == 2 && sessions[0].latest.provenance.tutor.thread.count == 3)

        store.undo()   // one step: payload AND size back
        sessions = TutorLayout.sessions(on: store.page)
        #expect(sessions[0].latest.provenance.turn == 1 && sessions[0].latest.frame.height == 100)

        store.perform([.delete(objectID: id)])                     // ✕ closes the whole session
        #expect(TutorLayout.sessions(on: store.page).isEmpty)
        store.undo()
        #expect(TutorLayout.sessions(on: store.page).count == 1)
    }
}
