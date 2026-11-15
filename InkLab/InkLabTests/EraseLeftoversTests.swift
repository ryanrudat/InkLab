import Testing
import Foundation
import UIKit
import PencilKit
import InkLabKit
@testable import InkLab

/// What the pixel eraser leaves behind is not writing: the tutor, Check, Recognize and the "@" scan never read
/// a half-rubbed-out word, and erasing never makes old ink look newly written.
@MainActor
struct EraseLeftoversTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    /// Letter `i` of a word at `x`: 12pt wide, 20pt tall, 2pt apart, written a second after the one before.
    private func letter(_ x: CGFloat, _ i: Int, shown: CGFloat = 1, stroke: Int? = nil, at: TimeInterval? = nil) -> InkGeometry.InkPiece {
        let whole = CGRect(x: x + CGFloat(i) * 14, y: 100, width: 12, height: 20)
        let bounds = shown < 1 ? CGRect(x: whole.minX, y: whole.minY, width: whole.width, height: whole.height * shown) : whole
        return InkGeometry.InkPiece(bounds: bounds, whole: whole, shown: shown, stroke: stroke ?? Int(x) * 100 + i,
                                    written: t0.addingTimeInterval(at ?? TimeInterval(i)))
    }

    /// The reported bug: a word rubbed out, with a few lines the eraser didn't quite get. All of it goes,
    /// including the stroke it missed altogether, and the word beside it stays.
    @Test func aWordRubbedOutIsNotReadEvenWithAFewLinesLeft() {
        let house = [letter(100, 0, shown: 0.3), letter(100, 1, shown: 0.55), letter(100, 3, shown: 0.2), letter(100, 4)]   // "u" is gone
        let big = (0..<3).map { letter(20, $0, at: -30 + TimeInterval($0)) }
        let page = big + house
        #expect(InkGeometry.eraseLeftovers(page) == Set(3..<7))
        // Writing it again on the same spot later is new writing, read as usual; the old bits still aren't.
        let dog = (0..<3).map { letter(100, $0, stroke: 900 + $0, at: 60 + TimeInterval($0)) }
        #expect(InkGeometry.eraseLeftovers(page + dog) == Set(3..<7))
    }

    /// Fixing a letter is not erasing the word: only the rubbed-out letter goes.
    @Test func aWordThatLostOneLetterIsStillRead() {
        let cart = [letter(100, 0), letter(100, 1), letter(100, 2), letter(100, 3, shown: 0.3)]
        #expect(InkGeometry.eraseLeftovers(cart) == [3])
        // A stroke trimmed at its end, or a letter cut through the middle (two pieces of one stroke), stays.
        let trimmed = [letter(100, 0, shown: 0.8), letter(100, 1)]
        #expect(InkGeometry.eraseLeftovers(trimmed).isEmpty)
        let cut = [letter(100, 0, shown: 0.53, stroke: 7), letter(100, 0, shown: 0.53, stroke: 7), letter(100, 1)]
        #expect(InkGeometry.eraseLeftovers(cut).isEmpty)
        #expect(InkGeometry.eraseLeftovers([letter(100, 0), letter(100, 1)]).isEmpty)   // never erased: nothing to do
    }

    @Test func wordsAreStrokesOnALineCloserThanAWordSpace() {
        let groups = InkGeometry.wordGroups([letter(20, 0), letter(20, 1), letter(100, 0), letter(100, 1)].map(\.whole)
                                            + [CGRect(x: 20, y: 160, width: 12, height: 20)])
        #expect(groups == [[0, 1], [2, 3], [4]])
    }

    // MARK: - Real PencilKit strokes

    private static func stroke(from x: CGFloat, to end: CGFloat, y: CGFloat = 10, date: Double, mask: UIBezierPath? = nil) -> PKStroke {
        let pts = (0...10).map { i in
            PKStrokePoint(location: CGPoint(x: x + (end - x) * CGFloat(i) / 10, y: y), timeOffset: TimeInterval(i) * 0.01,
                          size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSinceReferenceDate: date))
        return PKStroke(ink: PKInk(.pen, color: .black), path: path, transform: .identity, mask: mask)
    }

    /// The pixel eraser hides what it rubs out with a mask but keeps the stroke's whole path: only what shows
    /// is traced, lassoed and counted.
    @Test func onlyWhatStillShowsOfAStrokeCounts() throws {
        let whole = Self.stroke(from: 0, to: 100, date: 1)
        let erased = Self.stroke(from: 0, to: 100, date: 1, mask: UIBezierPath(rect: CGRect(x: -5, y: 0, width: 35, height: 20)))
        let pieces = PencilKitAdapters.inkPieces([whole, erased])
        #expect(pieces[0].shown == 1 && pieces[0].whole == whole.renderBounds)
        #expect(pieces[1].shown < 0.5)                                   // about a third of it is left
        #expect(pieces[1].whole.width > 90 && pieces[1].bounds.width < 50)
        let shown = PencilKitAdapters.visiblePaths(erased)
        #expect(shown.count == 1)
        #expect(try #require(shown.first).allSatisfy { $0.x <= 40 })
        #expect(PencilKitAdapters.eraseLeftovers([whole, erased]) == [1])
        #expect(PencilKitAdapters.readable(PKDrawing(strokes: [whole, erased])).strokes.count == 1)
    }

    /// Erasing cuts strokes in pieces and drops others, so the count shifts: the auto-scan finds where what
    /// it has read now ends, and never takes the last strokes on the page for new writing.
    @Test func erasingNeverMakesOldInkLookNew() {
        let a = Self.stroke(from: 0, to: 20, date: 1), b = Self.stroke(from: 30, to: 50, date: 2)
        let c = Self.stroke(from: 60, to: 80, date: 3), d = Self.stroke(from: 90, to: 110, date: 4)
        let b1 = Self.stroke(from: 30, to: 50, date: 2, mask: UIBezierPath(rect: CGRect(x: 25, y: 0, width: 8, height: 20)))
        let b2 = Self.stroke(from: 30, to: 50, date: 2, mask: UIBezierPath(rect: CGRect(x: 45, y: 0, width: 8, height: 20)))
        let after = CanvasViewController.examinedCountAfterChange
        #expect(after([a, b, c, d], [a, b1, b2, c, d], 4) == 5)       // all read: still all read
        #expect(after([a, b, c, d], [a, b1, b2, c, d], 3) == 4)       // "d" not read yet: still waiting
        let c1 = Self.stroke(from: 60, to: 80, date: 3, mask: UIBezierPath(rect: CGRect(x: 55, y: 0, width: 8, height: 20)))
        #expect(after([a, b, c], [a, b, c1], 2) == 3)                 // what's left of unread ink isn't writing
        #expect(after([a, b], [a, b, c], 2) == 3)                     // a redo brings back ink read before
        #expect(after([a, b], [a], 1) == 1)                           // an undo takes ink away
    }
}
