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
        let long = AtCommandChip.title(for: "@a solar system with all eight planets orbiting", engine: false)
        #expect(long.hasSuffix("…”") && long.count < 40)
        #expect(AtCommandChip.width(for: long) <= AtCommandChip.maxWidth)
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
