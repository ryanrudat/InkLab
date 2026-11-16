import Testing
import UIKit
@testable import InkLab

/// The "Designing…" card is the Home poster framed for a card: its sky has a galaxy, four kinds of craft and
/// lights along the skyway, and all of it stops when the card does.
@MainActor
struct DesigningPlaceholderTests {
    @Test func theCardIsThePosterWithCraftAndLights() {
        let card = DesigningPlaceholderView(prompt: "a solar system", pageID: UUID(),
                                            frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        card.layoutIfNeeded()
        #expect(card.craftRigs.count == DesigningArt.Craft.allCases.count)
        #expect(card.skywayLights.count >= 12)
        #expect(card.skywayLights.allSatisfy { card.bounds.contains($0.position) })
        #expect(card.accessibilityLabel == "Designing “a solar system”")
        // A night copy of the sky, dunes, city, galaxy, moon and every craft, to fade in as the sun sets.
        #expect(card.nightLayers.count == 5 + DesigningArt.Craft.allCases.count)
        card.stop()
        func animated(_ l: CALayer) -> Bool { !(l.animationKeys() ?? []).isEmpty || (l.sublayers ?? []).contains(where: animated) }
        #expect(!animated(card.layer))
    }

    /// Day to night and back: the sun is down whenever night is fully in, the moon is up only then, and a card
    /// shown in dark mode starts in the middle of the night.
    @Test func theSunSetsAsNightComesAndRisesAsItGoes() {
        typealias C = DesigningPlaceholderView.Cycle
        func at(_ track: (values: [Double], times: [Double]), _ t: Double) -> Double {
            let i = track.times.lastIndex { $0 <= t }!
            guard i + 1 < track.times.count else { return track.values[i] }
            let k = (t - track.times[i]) / (track.times[i + 1] - track.times[i])
            return track.values[i] + (track.values[i + 1] - track.values[i]) * k
        }
        for track in [C.night, C.sun, C.moon, C.dusk, C.ink] {
            #expect(track.values.count == track.times.count && track.times.first == 0 && track.times.last == 1)
            #expect(track.values.first == track.values.last)        // the cycle closes on itself
        }
        for t in stride(from: 0.0, through: 1.0, by: 0.01) {
            if at(C.night, t) == 1 { #expect(at(C.sun, t) == 1) }
            // The sky behind the title is dark whenever the title is in night ink: the glow or the night is up.
            if at(C.ink, t) == 1 { #expect(max(at(C.dusk, t), at(C.night, t)) == 1) }
        }
        #expect(at(C.night, 0.1) == 0 && at(C.sun, 0.1) == 0 && at(C.moon, 0.1) == 1)     // day: sun up, moon down
        let n = DesigningPlaceholderView.nightStart
        #expect(at(C.night, n) == 1 && at(C.moon, n) == 0)                                  // night: moon up
    }

    @Test func theCardFramesTheRightOfTheSceneWithSkyAbove() {
        let f = DesertFrame(card: CGSize(width: 360, height: 600), fromX: 860)
        #expect(abs(860 * f.scale + f.tx) < 0.001)               // the window starts at x 860
        #expect(abs(1500 * f.scale + f.tx - 360) < 0.001)        // and ends at the card's right edge
        #expect(abs(460 * f.scale + f.ty - 600) < 0.001)         // the desert's foot on the card's bottom edge
        let home = DesertFrame(size: CGSize(width: 1100, height: 330))
        #expect(home.ty == 0 && abs(home.scale - 330.0 / 460) < 0.001)
    }
}
