import Testing
import UIKit
@testable import InkLab

/// The write-here space for a reply to &Co can be pulled bigger or smaller by its edges, and the reply is read
/// from wherever it then reaches.
@MainActor
struct TutorWriteZoneTests {
    private let start = CGRect(x: 60, y: 400, width: 320, height: 110)

    @Test func pullingAnEdgeOrTheCornerResizesItFromTheTopLeft() {
        let resized = TutorWriteZoneView.resized
        #expect(resized(start, CGPoint(x: 40, y: 90), .bottom, 820) == CGRect(x: 60, y: 400, width: 320, height: 200))
        #expect(resized(start, CGPoint(x: 120, y: 90), .right, 820) == CGRect(x: 60, y: 400, width: 440, height: 110))
        #expect(resized(start, CGPoint(x: 120, y: 90), [.right, .bottom], 820) == CGRect(x: 60, y: 400, width: 440, height: 200))
        // It keeps a size worth writing in, stays inside the page's margin, and doesn't grow without end.
        #expect(resized(start, CGPoint(x: -500, y: -500), [.right, .bottom], 820).size == TutorWriteZoneView.minSize)
        #expect(resized(start, CGPoint(x: 900, y: 0), .right, 820).maxX == CGFloat(820 - 16))
        #expect(resized(start, CGPoint(x: 0, y: 5000), .bottom, 820).height == TutorWriteZoneView.maxHeight)
    }

    @Test func onlyTheGripsAndTheCloseButtonTakeATouch() throws {
        let zone = TutorWriteZoneView(frame: start)
        zone.layoutIfNeeded()
        let local = zone.bounds
        #expect(zone.hitTest(CGPoint(x: local.midX, y: local.midY), with: nil) == nil)          // the Pencil writes here
        #expect(zone.hitTest(CGPoint(x: local.midX, y: local.maxY), with: nil) is TutorWriteZoneView.Grip)
        #expect(zone.hitTest(CGPoint(x: local.maxX, y: local.midY), with: nil) is TutorWriteZoneView.Grip)
        #expect(zone.hitTest(CGPoint(x: local.maxX - 2, y: local.maxY - 2), with: nil) is TutorWriteZoneView.Grip)
        // VoiceOver: the corner grip makes it a line taller or shorter, and the canvas hears about it.
        var reported: CGRect?
        zone.onResize = { reported = $0 }
        let corner = try #require(zone.subviews.compactMap { $0 as? TutorWriteZoneView.Grip }.first { $0.accessibilityTraits.contains(.adjustable) })
        corner.accessibilityIncrement()
        #expect(zone.frame.height == start.height + TutorWriteZoneView.step && reported == zone.frame)
        corner.accessibilityDecrement()
        #expect(zone.frame.height == start.height)
    }

    @Test func itOpensAgainAtTheSizeItWasPulledTo() {
        let problem = CGRect(x: 60, y: 200, width: 240, height: 120)
        let usual = TutorLayout.writeZone(problem: problem, avoiding: [], canvasWidth: 820)
        #expect(usual.height == TutorNoteStyle.current.writeZoneHeight)
        let pulled = TutorLayout.writeZone(problem: problem, avoiding: [], canvasWidth: 820, size: CGSize(width: 500, height: 260))
        #expect(pulled.size == CGSize(width: 500, height: 260) && pulled.minY == usual.minY)
        // Never wider than the page.
        #expect(TutorLayout.writeZone(problem: problem, avoiding: [], canvasWidth: 400, size: CGSize(width: 900, height: 200)).width == CGFloat(400 - 32))
    }
}
