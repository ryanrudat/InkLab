import Testing
import UIKit
@testable import InkLab

/// A handwritten "@" command never runs on its own: it waits as a tap-to-make chip beside the writing.
@MainActor
struct AtCommandChipTests {
    @Test func theChipSaysWhatItWillMake() {
        #expect(AtCommandChip.title(for: "@a clock", engine: false) == "Make “a clock”")
        #expect(AtCommandChip.title(for: "@ a piano", engine: false) == "Make “a piano”")
        #expect(AtCommandChip.title(for: "@balance H2 + O2", engine: true) == "Run “@balance H2 + O2”")
        // A long one keeps its start and its end, so the last words written (often on the next line) show.
        let long = AtCommandChip.title(for: "@a solar system with all eight planets orbiting", engine: false)
        #expect(long == "Make “a solar system … orbiting”")
        #expect(AtCommandChip.width(for: long) <= AtCommandChip.maxWidth)
        let chip = AtCommandChip(command: "@a solar system with all eight planets orbiting", engine: false, pageID: UUID())
        #expect(chip.accessibilityLabel == "Make “a solar system with all eight planets orbiting”")   // VoiceOver: all of it
    }

    /// A command written over several lines is still one command.
    @Test func aCommandCarriesOnOverTheLinesAfterIt() {
        let read = CanvasViewController.extractAtCommands
        #expect(read("@a solar system with\nall eight planets") == ["@a solar system with all eight planets"])
        #expect(read("@a solar sys-\ntem with rings") == ["@a solar system with rings"])        // a word split over the break
        #expect(read("@\na clock") == ["@ a clock"])                                          // the "@" alone on its line
        #expect(AtCommandChip.title(for: read("@\na clock")[0], engine: false) == "Make “a clock”")
        #expect(read("notes first\n@a clock\nwith hands") == ["@a clock with hands"])         // notes before it don't count
        #expect(read("@a clock\nwith hands\n@a piano") == ["@a clock with hands", "@a piano"])
        #expect(read("@").isEmpty && read("just\nnotes").isEmpty)
    }

    // MARK: - A command written at a normal pace: a line at a time, with a pause after each

    private let t0 = Date(timeIntervalSinceReferenceDate: 5_000)
    private let page = UUID()
    /// "@" and "a solar system with" on one line, 36pt tall.
    private var firstLine: [CGRect] { [CGRect(x: 100, y: 100, width: 36, height: 36), CGRect(x: 150, y: 104, width: 200, height: 30)] }

    @Test func theNextLineJoinsTheCommandInsteadOfBeingLost() throws {
        let draft = try #require(AtDraft(read: "@a solar system with", ink: firstLine, page: page, now: t0))
        #expect(draft.command == "@a solar system with")
        // Pause, then "all eight planets" on the line below: read on its own it has no "@", but it carries on.
        let line2 = CGRect(x: 100, y: 150, width: 180, height: 30)
        let next = try #require(draft.continued(by: "all eight planets", at: line2, now: t0 + 10))
        #expect(next.command == "@a solar system with all eight planets")
        #expect(next.extent.contains(firstLine[1]) && next.extent.contains(line2))   // the chip goes above all of it
        // More along that line after another pause: the scan reads the whole line again, so it's replaced.
        let more = try #require(next.continued(by: "all eight planets orbiting", at: CGRect(x: 100, y: 150, width: 260, height: 32), now: t0 + 20))
        #expect(more.command == "@a solar system with all eight planets orbiting")
        // When only the new words could be read (the start of the line is too old to read again), they're added.
        let added = try #require(more.continued(by: "the sun", at: CGRect(x: 380, y: 151, width: 60, height: 28), now: t0 + 30))
        #expect(added.command == "@a solar system with all eight planets orbiting the sun")
    }

    @Test func rereadingTheAtLineKeepsItsAtEvenWhenTheReadingLosesIt() throws {
        let draft = try #require(AtDraft(read: "@a solar system", ink: [firstLine[0], CGRect(x: 150, y: 104, width: 150, height: 30)], page: page, now: t0))
        // A handwritten "@" read again as "a": the words already known stay a command, with what was added.
        let next = try #require(draft.continued(by: "aa solar system with", at: CGRect(x: 100, y: 100, width: 260, height: 36), now: t0 + 5))
        #expect(next.command == "@a solar system with")
    }

    @Test func writingElsewhereOrLaterIsNotPartOfTheCommand() throws {
        let draft = try #require(AtDraft(read: "@a solar system with", ink: firstLine, page: page, now: t0))
        let line2 = CGRect(x: 100, y: 150, width: 180, height: 30)
        #expect(draft.continued(by: "all eight planets", at: line2, now: t0 + 61) == nil)                       // a minute on
        #expect(draft.continued(by: "the next problem", at: CGRect(x: 100, y: 300, width: 180, height: 30), now: t0 + 5) == nil)   // further down
        #expect(draft.continued(by: "a note", at: CGRect(x: 700, y: 100, width: 40, height: 36), now: t0 + 5) == nil)   // far along the line
        #expect(draft.continued(by: "@a moon", at: line2, now: t0 + 5) == nil)                                  // a command of its own
        #expect(draft.continued(by: "", at: line2, now: t0 + 5) == nil)
        // Written over two lines without a pause: one reading, and the draft is on its second line.
        let two = try #require(AtDraft(read: "@a solar\nsystem with", ink: firstLine + [line2], page: page, now: t0))
        #expect(two.command == "@a solar system with" && two.lineBand == line2)
        #expect(AtDraft(read: "just notes", ink: firstLine, page: page, now: t0) == nil)
    }

    @Test func chipsSitAboveTheEndOfTheWritingSoTheNextWordsNeverLandOnOne() {
        let ink = CGRect(x: 100, y: 300, width: 160, height: 40)
        let above = AtCommandChip.frames(widths: [150, 120], near: ink, canvasWidth: 820)
        #expect(above[0] == CGRect(x: 110, y: 216, width: 150, height: AtCommandChip.height))   // right edge = end of the ink
        #expect(above[1] == CGRect(x: 140, y: 258, width: 120, height: AtCommandChip.height))
        #expect(above.allSatisfy { $0.maxY <= ink.minY })
        // At the top of the page there's no room above: under the writing instead.
        let top = CGRect(x: 100, y: 20, width: 160, height: 40)
        #expect(AtCommandChip.frames(widths: [150], near: top, canvasWidth: 820)[0].minY == top.maxY + 6)
        // Never off the page.
        let edge = AtCommandChip.frames(widths: [300], near: CGRect(x: 0, y: 300, width: 40, height: 40), canvasWidth: 820)[0]
        #expect(edge.minX >= 8 && edge.maxX <= 812)
    }

    /// Written at a normal pace, a command arrives in pieces ("@" … pause … "a clock"): what was just written
    /// on the same line is read again with the rest, word by word along it, and nothing from other lines is.
    @Test func aCommandWrittenInPiecesIsReadAsOneLine() {
        let at = CGRect(x: 100, y: 300, width: 36, height: 36)
        let a = CGRect(x: 158, y: 312, width: 20, height: 20)
        let below = CGRect(x: 100, y: 420, width: 80, height: 30)       // the next problem down the page
        let farOff = CGRect(x: 700, y: 305, width: 40, height: 28)      // same height, other side of the page
        let clock = [CGRect(x: 210, y: 300, width: 128, height: 34)]
        #expect(InkGeometry.lineMates([at, a, below, farOff], of: clock) == [0, 1])
        // Word by word: "@" is too far from the last word on its own, but "a clock" carries the line to it.
        let tail = [CGRect(x: 420, y: 302, width: 90, height: 30)]
        #expect(InkGeometry.lineMates([at, a, clock[0]], of: tail) == [0, 1, 2])
        #expect(InkGeometry.lineMates([at], of: []).isEmpty)
        #expect(!InkGeometry.onSameLine(below, as: clock))
    }

    /// While the student is still writing nothing is offered: the chip waits until writing has stopped (about
    /// 3 s after the last stroke) and the Pencil isn't hovering over the page, and the newest read wins.
    @Test func theChipWaitsUntilWritingHasStopped() {
        let start = Date(timeIntervalSinceReferenceDate: 9_000)
        var wait = AtOfferWait()
        #expect(wait.wait(now: start) == nil)                                    // nothing to offer
        wait.lastStroke = start
        let clock = AtOfferWait.Offer(commands: ["@a clock"], near: .zero, page: page)
        wait.read(clock)                                                         // read after a 1.5 s pause…
        #expect(wait.wait(now: start + 1.5) == 1.5)                              // …offered 3 s after the last stroke
        #expect(wait.take(now: start + 1.5) == nil)
        // Another stroke restarts the wait, and the next read's command replaces this one.
        wait.lastStroke = start + 2
        #expect(wait.take(now: start + 3.5) == nil)
        let withHands = AtOfferWait.Offer(commands: ["@a clock with hands"], near: .zero, page: page)
        wait.read(withHands)
        // The Pencil hovering over the page holds it back however long; lifted away, it comes at once.
        wait.hovering = true
        #expect(wait.wait(now: start + 10) == nil && wait.take(now: start + 10) == nil)
        wait.hovering = false
        #expect(wait.wait(now: start + 10) == 0)
        #expect(wait.take(now: start + 10) == withHands)
        #expect(wait.take(now: start + 11) == nil)                               // offered once
        // A read with nothing to offer (writing on that isn't a command) means nothing comes.
        wait.read(clock)
        wait.read(nil)
        #expect(wait.wait(now: start + 20) == nil)
    }

    @Test func onlyATapMakesIt() {
        let chip = AtCommandChip(command: "@a clock", engine: false, pageID: UUID())
        var made: [String] = []
        chip.onMake = { made.append(chip.command) }
        #expect(chip.accessibilityLabel == "Make “a clock”")
        #expect(chip.accessibilityTraits.contains(.button))
        #expect(made.isEmpty)                              // showing it runs nothing
        _ = chip.accessibilityActivate()
        #expect(made == ["@a clock"])
        // Leaving it alone (or writing on) takes it away without making anything.
        let host = UIView()
        let other = AtCommandChip(command: "@a piano", engine: false, pageID: UUID())
        var otherMade = false
        other.onMake = { otherMade = true }
        host.addSubview(other)
        other.dismiss(animated: false)
        #expect(other.superview == nil && !otherMade)
    }
}
