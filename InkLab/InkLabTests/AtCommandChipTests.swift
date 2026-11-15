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

    @Test func chipsSitBesideTheWritingOrUnderItWhenTheresNoRoom() {
        let ink = CGRect(x: 100, y: 300, width: 160, height: 40)
        let beside = AtCommandChip.frames(widths: [150, 120], near: ink, canvasWidth: 820)
        #expect(beside[0] == CGRect(x: 272, y: 300, width: 150, height: AtCommandChip.height))
        #expect(beside[1].minY == beside[0].maxY + 8 && beside[1].minX == 272)
        // Writing near the right edge: the chips go under it instead, still on the page.
        let edge = CGRect(x: 600, y: 300, width: 180, height: 40)
        let under = AtCommandChip.frames(widths: [200], near: edge, canvasWidth: 820)
        #expect(under[0].minY == edge.maxY + 8)
        #expect(under[0].maxX <= 812 && under[0].minX >= 8)
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
