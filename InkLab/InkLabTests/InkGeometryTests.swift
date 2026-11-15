import Testing
import Foundation
import UIKit
@testable import InkLab

/// Reading where the student wrote from the strokes themselves: the piece of writing a tutor request is
/// about, its lines and words, and the words a tutor message points at.
@MainActor
struct InkGeometryTests {
    /// One handwritten word: `letters` print letters 12pt wide and 20pt tall, 2pt apart.
    private func word(_ x: CGFloat, _ y: CGFloat, letters: Int) -> [CGRect] {
        (0..<letters).map { CGRect(x: x + CGFloat($0) * 14, y: y, width: 12, height: 20) }
    }
    private func union(_ rects: [CGRect]) -> CGRect { rects.dropFirst().reduce(rects[0]) { $0.union($1) } }

    // "The Civil War" / "started because of taxes", in two lines 36pt apart (as on ruled paper).
    private var line1: [[CGRect]] { [word(50, 100, letters: 3), word(106, 100, letters: 5), word(190, 100, letters: 3)] }
    private var line2: [[CGRect]] { [word(50, 136, letters: 7), word(162, 136, letters: 7), word(274, 136, letters: 2), word(316, 136, letters: 5)] }
    private var paragraph: [CGRect] { (line1 + line2).flatMap { $0 } }

    @Test func aParagraphIsOnePieceOfWritingAndABlankLineStartsAnother() {
        let later = word(50, 260, letters: 4)        // a new problem further down
        let blocks = InkGeometry.blocks(paragraph + later)
        #expect(blocks.count == 2)
        #expect(blocks[0] == Array(paragraph.indices))
        #expect(blocks[1] == Array(paragraph.count..<(paragraph.count + later.count)))
        // Working with a line left between the steps is still one problem.
        let spaced = word(50, 100, letters: 4) + word(50, 156, letters: 4) + word(50, 212, letters: 3)
        #expect(InkGeometry.blocks(spaced).count == 1)
    }

    @Test func withNoLassoTheTutorReadsWhatWasWrittenLastOnScreen() {
        let earlier = word(50, 400, letters: 4)
        let strokes = earlier + paragraph             // the paragraph was written after
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(InkGeometry.latestBlock(strokes: strokes, visible: screen) == Array(earlier.count..<strokes.count))
        // Ink scrolled off screen doesn't count, even if it is newer.
        let offscreen = word(50, 1400, letters: 3)
        #expect(InkGeometry.latestBlock(strokes: strokes + offscreen, visible: screen) == Array(earlier.count..<strokes.count))
        #expect(InkGeometry.latestBlock(strokes: [], visible: screen).isEmpty)
    }

    @Test func linesAreFoundFromTheInkAndAnIDotStaysOnItsLine() {
        let dot = CGRect(x: 120, y: 92, width: 4, height: 4)   // the dot of the "i" in "Civil", above the line
        let rows = InkGeometry.rows(paragraph + [dot])
        #expect(rows.count == 2)
        #expect(rows[0] == union(line1.flatMap { $0 } + [dot]))
        #expect(rows[1] == union(line2.flatMap { $0 }))
        // A reading with one line fewer (one long line read as one): the two closest bands merge.
        #expect(InkGeometry.lines(paragraph, count: 1) == [union(paragraph)])
        // One more line than the ink shows (a long line the reading broke): the widest band splits in two.
        let three = InkGeometry.lines(paragraph, count: 3)
        #expect(three?.count == 3 && three?[1].minX == union(line2.flatMap { $0 }).minX)
        #expect(InkGeometry.lines([], count: 2) == nil)
    }

    @Test func aLineSplitsIntoItsWords() {
        let words = InkGeometry.words(line2.flatMap { $0 })
        #expect(words == line2.map(union))
    }

    @Test func quotesAndLineNumbersAreFoundInTheMessage() {
        #expect(TutorFocus.quotes(in: "You wrote “because of taxes”: which taxes?") == ["because of taxes"])
        #expect(TutorFocus.quotes(in: #"Look at "The Civil War" and 'started because' here."#) == ["The Civil War", "started because"])
        #expect(TutorFocus.quotes(in: "What's your main point? Don't rush.").isEmpty)   // apostrophes aren't quotes
        #expect(TutorFocus.lineNumbers(in: "Look at line 2, then Line 3.") == [2, 3])
    }

    @Test func aQuoteLightsUpThoseWordsOnThePage() throws {
        let problem = union(paragraph).insetBy(dx: -12, dy: -12)
        guard case .success(let s) = TutorSession.start(read: "The Civil War\nstarted because of taxes", problem: problem,
                                                        strokes: paragraph) else { Issue.record("no session"); return }
        #expect(s.isWriting)
        let focus = TutorFocus.rects(for: "You wrote “because of taxes”: which taxes do you mean?", session: s, ink: paragraph)
        #expect(focus == [union(line2[1] + line2[2] + line2[3])])
        // Across a line break: one spot per line.
        let wrapped = TutorFocus.rects(for: "What does \"War started\" tell the reader?", session: s, ink: paragraph)
        #expect(wrapped == [union(line1[2]), union(line2[0])])
        // A quote that isn't their writing (the level-4 example) points at nothing.
        #expect(TutorFocus.rects(for: "Here's the move: \"Our team lost the game.\" Can you try it?", session: s, ink: paragraph).isEmpty)
        // When the words were read differently from how the ink splits, the letters' place on the line still finds them.
        let joined = paragraph.filter { $0.minY != 136 } + [union(line2[0] + line2[1])] + line2[2] + line2[3]
        let approx = TutorFocus.rects(for: "You wrote “taxes”.", session: s, ink: joined)
        #expect(approx == [union(line2[3])])
    }

    @Test func mathNamesALineAndTheNoteGoesThere() {
        let rows = [CGRect(x: 50, y: 100, width: 180, height: 20), CGRect(x: 50, y: 150, width: 120, height: 22),
                    CGRect(x: 52, y: 200, width: 90, height: 18)]
        let problem = CGRect(x: 40, y: 90, width: 210, height: 140)
        guard case .success(var s) = TutorSession.start(read: "2x + 3 = 7\n2x = 10\nx = 5", problem: problem, strokes: rows) else {
            Issue.record("no session"); return
        }
        let focus = TutorFocus.rects(for: "Look at line 2: what did you do to both sides?", session: s, ink: rows)
        #expect(focus == [rows[1]])
        s.focus = [rows[2]]
        #expect(s.anchorRect == rows[2])            // the note points at what the message is about
        // A note saved before lines came from the ink has one band for the whole problem: only the real ink
        // on it lights up, never stray dots, and with no ink nothing does.
        let old = TutorSession(problem: problem, pageLines: ["1+3="], lineRects: [problem], anchorLine: 1, lines: ["1+3="])
        let dot = CGRect(x: 240, y: 220, width: 3, height: 3)
        #expect(TutorFocus.rects(for: "Look at line 1.", session: old, ink: [rows[0], dot]) == [rows[0]])
        #expect(TutorFocus.rects(for: "Look at line 1.", session: old, ink: []).isEmpty)
    }

    @Test func theNoteLightsUpWhatItMeans() {
        let note = TutorNoteView(frame: CGRect(x: 0, y: 0, width: 280, height: 160))
        note.anchorInSelf = CGPoint(x: -40, y: 20)
        note.focusInSelf = [CGRect(x: -200, y: 10, width: 80, height: 20)]
        #expect(note.focusCount == 1)
        note.focusInSelf = []
        #expect(note.focusCount == 0)
    }

    @Test func theScanTracesTheStrokesNotABox() {
        let scan = InkScanView(strokes: [[CGPoint(x: 100, y: 100), CGPoint(x: 160, y: 120)], [CGPoint(x: 120, y: 200)]])
        #expect(scan.frame == CGRect(x: 86, y: 86, width: 88, height: 128))
        #expect(scan.isUserInteractionEnabled == false)
    }
}
