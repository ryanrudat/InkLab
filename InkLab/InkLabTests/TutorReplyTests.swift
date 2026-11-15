import Testing
import Foundation
import UIKit
@testable import InkLab

/// Which tutor conversation new ink is a reply to (`TutorLayout.replyTarget`). Only writing that belongs
/// to the conversation counts: in the write-here space, on or joined to the problem's ink, or right by the
/// note. A new problem lower on the page is left alone, however close the old 100 pt zone would have been.
@MainActor
struct TutorReplyTests {
    /// One handwritten word: `letters` print letters 12pt wide and 20pt tall, 2pt apart (letter height 20).
    private func word(_ x: CGFloat, _ y: CGFloat, letters: Int) -> [CGRect] {
        (0..<letters).map { CGRect(x: x + CGFloat($0) * 14, y: y, width: 12, height: 20) }
    }
    private func union(_ rects: [CGRect]) -> CGRect { rects.dropFirst().reduce(rects[0]) { $0.union($1) } }

    // "1+3=" on one line, the note in the margin beside it (as `startTutor` and `marginFrame` place them).
    private var problemInk: [CGRect] { word(50, 100, letters: 4) }
    private var problem: CGRect { union(problemInk).insetBy(dx: -12, dy: -12) }
    private let note = CGRect(x: 150, y: 80, width: 280, height: 150)
    private let id = UUID()
    private var session: TutorLayout.ReplyCandidate { .init(id: id, problem: problem, notes: [note]) }

    private func target(_ new: [CGRect], old: [CGRect]? = nil, sessions: [TutorLayout.ReplyCandidate]? = nil,
                        zone: (session: UUID, rect: CGRect)? = nil) -> UUID? {
        TutorLayout.replyTarget(newInk: new, oldInk: old ?? problemInk, sessions: sessions ?? [session], writeZone: zone)
    }

    /// The live bug: "2x + 3 = 7" written as a new problem under the old "1+3=" note was sent to that
    /// conversation ("That looks like a different problem").
    @Test func aNewProblemLowerOnThePageIsNotAReply() {
        let newProblem = word(50, 300, letters: 6)
        #expect(problem.union(note).insetBy(dx: -100, dy: -100).intersects(union(newProblem)), "the old zone took it")
        #expect(target(newProblem) == nil)
        // Not by the note either: under it, past a letter height and a half.
        #expect(target(word(160, 270, letters: 6)) == nil)
    }

    @Test func writingUnderTheWorkingOrOnItIsAReply() {
        #expect(target(word(50, 136, letters: 5)) == id)          // the next line
        #expect(target(word(50, 160, letters: 5)) == id)          // a line left between, still one piece
        #expect(target(word(120, 100, letters: 2)) == id)         // finishing the line: "1+3= 4"
        #expect(target([CGRect(x: 60, y: 104, width: 30, height: 10)]) == id)   // over the old ink
        // Two lines of reply that run on down the page are one piece with the problem.
        #expect(target(word(50, 136, letters: 5) + word(50, 172, letters: 4)) == id)
    }

    @Test func writingRightByTheNoteIsAReply() {
        #expect(target(word(160, 250, letters: 4)) == id)         // just under the note, far from the ink
        #expect(target(word(440, 120, letters: 3)) == id)         // just right of it
        #expect(target(word(160, 290, letters: 4)) == nil)        // a clear gap below it
    }

    /// A batch that is partly a reply and partly a new problem is not sent: the new problem would ride along.
    @Test func aBatchThatAlsoStartsANewPieceIsNotAReply() {
        #expect(target(word(50, 136, letters: 5) + word(50, 400, letters: 6)) == nil)
    }

    @Test func theWriteHereSpaceIsAlwaysAReply() {
        let zone = CGRect(x: 40, y: 500, width: 300, height: 120)
        let inZone = word(70, 540, letters: 5)
        #expect(target(inZone) == nil)                                        // far from the conversation…
        #expect(target(inZone, zone: (session: id, rect: zone)) == id)        // …but written where it asked
        // A space left open for a conversation that's gone from the page counts for nothing.
        #expect(target(inZone, zone: (session: UUID(), rect: zone)) == nil)
        // Ink outside the space still goes by where it was written.
        #expect(target(word(50, 136, letters: 5), zone: (session: id, rect: zone)) == id)
        #expect(target(word(50, 300, letters: 6), zone: (session: id, rect: zone)) == nil)
    }

    /// A note that couldn't read its problem: writing it again over the old scrawl, or right beside it,
    /// re-reads it (the canvas sends it to `rereadTutorProblem`); a new problem further down doesn't.
    @Test func anUnreadProblemWrittenAgainOverOrBesideItCounts() {
        let scrawl = (0..<4).map { CGRect(x: 70 + CGFloat($0) * 14, y: 300, width: 12, height: 32) }
        let problem = union(scrawl).insetBy(dx: -12, dy: -12)
        let unread = TutorLayout.ReplyCandidate(id: id, problem: problem, notes: [])   // the ink alone decides
        let check = { (new: [CGRect]) in target(new, old: scrawl, sessions: [unread]) }
        #expect(check(word(75, 305, letters: 4)) == id)           // over it
        #expect(check(word(150, 305, letters: 4)) == id)          // right beside it
        #expect(check(word(70, 345, letters: 4)) == id)           // right under it
        #expect(check(word(70, 520, letters: 4)) == nil)          // a new problem lower down
        // Its ink was erased first: written in its place still counts.
        #expect(target(word(75, 305, letters: 4), old: [], sessions: [unread]) == id)
    }

    @Test func otherInkOnThePageIsNotTheProblems() {
        // Old writing near the new problem doesn't pull it into the conversation: only the problem's own ink does.
        let notes = word(50, 330, letters: 8)
        #expect(target(word(50, 300, letters: 6), old: problemInk + notes) == nil)
    }

    @Test func betweenTwoConversationsTheNearerProblemWins() {
        let ink2 = word(50, 170, letters: 4)
        let second = TutorLayout.ReplyCandidate(id: UUID(), problem: union(ink2).insetBy(dx: -12, dy: -12), notes: [])
        let both = [session, second]
        // Both join it (the two problems are a line apart); the order they're listed in doesn't decide.
        #expect(target(word(50, 128, letters: 3), old: problemInk + ink2, sessions: both.reversed()) == id)
        #expect(target(word(50, 140, letters: 3), old: problemInk + ink2, sessions: both) == second.id)
        #expect(target([], sessions: both) == nil)
    }
}
