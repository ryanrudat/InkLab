import SwiftUI
import UIKit

/// The pieces of the "Designing" card's poster that the Home header doesn't have: a hazy spiral galaxy, the
/// craft that cross its sky, and a field of stars for a sky taller than the header's. Drawn in the Home
/// scene's palette and flat poster style, and rendered once into images the card then moves with Core
/// Animation, so nothing is redrawn while it plays.
enum DesigningArt {
    /// Renders vector drawing into an image of `size` points (transparent where nothing is drawn).
    static func image(_ size: CGSize, scale: CGFloat, _ draw: @escaping (inout GraphicsContext, CGSize) -> Void) -> CGImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let renderer = ImageRenderer(content: Canvas { ctx, size in draw(&ctx, size) }.frame(width: size.width, height: size.height))
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.cgImage
    }

    // MARK: Galaxy

    /// A hazy two-armed spiral, face on (the card tilts and squashes it into a disc seen at an angle, and
    /// turns it slowly). Soft blobs of color, blurred, with a sprinkle of sharp stars along the arms.
    static func drawGalaxy(_ ctx: inout GraphicsContext, _ size: CGSize, _ p: DesertPalette) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let s = min(size.width, size.height)
        let night = p.isNight
        // By day the spiral is dusty rose and lavender on the peach sky, a little stronger so it still reads.
        let core = night ? Color(rgb: 0xF4EAD7) : Color(rgb: 0xFFF3E0)
        let haze = night ? Color(rgb: 0x6E6A9E) : Color(rgb: 0xEDB394)
        let arms = night ? [Color(rgb: 0x9C95D6), Color(rgb: 0x7ED3CE)] : [Color(rgb: 0xD9846A), Color(rgb: 0xA48FCB)]
        let strength: Double = night ? 1 : 1.35
        var rng = Seeded(7)

        func glow(_ at: CGPoint, _ r: CGFloat, _ color: Color, _ alpha: Double) -> (Path, GraphicsContext.Shading) {
            (Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r)),
             .radialGradient(Gradient(colors: [color.opacity(alpha * strength), color.opacity(0)]), center: at, startRadius: 0, endRadius: r))
        }

        ctx.drawLayer { soft in
            soft.addFilter(.blur(radius: s * 0.018))
            let disc = glow(c, s * 0.5, haze, night ? 0.32 : 0.28)
            soft.fill(disc.0, with: disc.1)
            for arm in 0..<2 {
                for i in 0..<120 {
                    let t = CGFloat(i) / 120
                    let angle = t * 3.4 * .pi + CGFloat(arm) * .pi
                    let r = s * (0.05 + 0.40 * t)
                    let spread = s * (0.012 + 0.05 * t)
                    let at = CGPoint(x: c.x + r * cos(angle) + rng.next(spread), y: c.y + r * sin(angle) + rng.next(spread))
                    let blob = glow(at, s * (0.055 - 0.025 * t), arms[(i / 7 + arm) % 2], 0.16 - 0.07 * Double(t))
                    soft.fill(blob.0, with: blob.1)
                }
            }
            let bulge = glow(c, s * 0.16, core, 0.95)
            soft.fill(bulge.0, with: bulge.1)
        }
        // Fine star dust along the arms: many small, faint points (kept tiny, so the disc's tilt can't stretch
        // them into dashes), thinning out toward the rim.
        for arm in 0..<2 {
            for i in 0..<150 {
                let t = CGFloat(i) / 150
                let angle = t * 3.4 * .pi + CGFloat(arm) * .pi + 0.08
                let r = s * (0.06 + 0.40 * t)
                let at = CGPoint(x: c.x + r * cos(angle) + rng.next(s * 0.035), y: c.y + r * sin(angle) + rng.next(s * 0.035))
                let d: CGFloat = 0.45 + 0.35 * CGFloat(i % 3)
                ctx.fill(Path(ellipseIn: CGRect(x: at.x - d, y: at.y - d, width: 2 * d, height: 2 * d)),
                         with: .color(core.opacity((night ? 0.8 : 0.55) * (1 - 0.6 * Double(t)))))
            }
        }
    }

    // MARK: Stars

    /// Stars over a card's whole sky at night (the Home header's own stars only cover its strip), kept off the
    /// bottom where the desert is. Fractions of the card, so every size gets the same sky.
    static let cardStars: [(x: CGFloat, y: CGFloat, r: CGFloat)] = {
        var rng = Seeded(31)
        return (0..<46).map { _ in (x: rng.unit(), y: rng.unit() * 0.62, r: 0.7 + rng.unit() * 0.9) }
    }()

    /// The stars that twinkle (fractions of the card).
    static let twinkles: [(x: CGFloat, y: CGFloat)] = [(0.12, 0.30), (0.46, 0.14), (0.83, 0.42), (0.30, 0.52), (0.64, 0.33), (0.92, 0.10)]

    // MARK: Craft

    /// The craft that cross the card's sky, each in its own style. Drawn nose to the right; the card mirrors
    /// one to fly it the other way.
    enum Craft: CaseIterable {
        /// The Home header's craft: a slim silver hull with a vapour trail.
        case cigar
        /// A domed saucer with a ring of rim lights.
        case saucer
        /// A finned rocket with a porthole (its flame is drawn apart so it can flicker).
        case rocket
        /// A small ringed sphere, far off.
        case ringed

        var size: CGSize {
            switch self {
            case .cigar: CGSize(width: 132, height: 22)
            case .saucer: CGSize(width: 70, height: 36)
            case .rocket: CGSize(width: 84, height: 34)
            case .ringed: CGSize(width: 46, height: 30)
            }
        }

        func draw(_ ctx: inout GraphicsContext, _ p: DesertPalette) {
            let light = p.isNight ? p.windows : Color(rgb: 0xE8742F)
            switch self {
            case .cigar:
                let x: CGFloat = 112, y: CGFloat = 10
                let trail = Path { $0.move(to: CGPoint(x: x - 92, y: y + 7.5)); $0.addLine(to: CGPoint(x: x - 14, y: y + 1.5)) }
                ctx.stroke(trail, with: .linearGradient(Gradient(colors: [p.trail.opacity(0), p.trail]),
                                                        startPoint: CGPoint(x: x - 92, y: 0), endPoint: CGPoint(x: x - 12, y: 0)),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))
                // a swept tail fin, the hull, a sheen along its top, and a row of portholes
                ctx.fill(DesertScene.svg { $0.move(x - 14, y - 2); $0.line(x - 19, y - 8); $0.line(x - 14, y - 8); $0.line(x - 7, y - 3) },
                         with: .color(p.craft))
                ctx.fill(Path(ellipseIn: CGRect(x: x - 16, y: y - 5, width: 32, height: 10)), with: .color(p.craft))
                ctx.fill(Path(ellipseIn: CGRect(x: x - 12, y: y - 4.2, width: 20, height: 3)), with: .color(p.towerLit.opacity(0.55)))
                for dx in [-6.0, -1, 4] as [CGFloat] {
                    ctx.fill(DesertScene.circle(x + dx, y + 1.2, 0.9), with: .color(p.isNight ? p.windows : p.towerLit.opacity(0.8)))
                }
                if p.isNight { ctx.fill(DesertScene.circle(x + 11, y, 1.8), with: .color(p.windows)) }
            case .saucer:
                // dome, then the disc's top and its darker underside
                ctx.fill(DesertScene.svg { $0.move(22, 17); $0.curve(23, 6, 30, 2, 35, 2); $0.curve(40, 2, 47, 6, 48, 17) }, with: .color(p.domeLit))
                ctx.fill(DesertScene.svg { $0.move(38, 3); $0.curve(44, 5, 47, 10, 48, 17); $0.line(41, 17); $0.curve(42, 11, 41, 6, 38, 3) },
                         with: .color(p.domeShade))
                ctx.fill(Path(ellipseIn: CGRect(x: 2, y: 13, width: 66, height: 13)), with: .color(p.platTop))
                ctx.fill(DesertScene.svg { $0.move(2, 19.5); $0.curve(10, 25, 24, 28, 35, 28); $0.curve(46, 28, 60, 25, 68, 19.5)
                    $0.curve(66, 26, 52, 31, 35, 31); $0.curve(18, 31, 4, 26, 2, 19.5) }, with: .color(p.platUnder))
                for x in [10.0, 22, 35, 48, 60] as [CGFloat] {
                    ctx.fill(DesertScene.circle(x, 24.5 - abs(x - 35) * 0.06, 1.6), with: .color(light))
                }
                ctx.fill(Path(ellipseIn: CGRect(x: 27, y: 30, width: 16, height: 4)), with: .color(light.opacity(0.45)))
            case .rocket:
                // fins first (behind the hull), then the hull lit on top, shaded below, nose cone, porthole
                ctx.fill(DesertScene.svg { $0.move(30, 12); $0.line(16, 2); $0.line(10, 2); $0.line(18, 13) }, with: .color(p.mesaMid))
                ctx.fill(DesertScene.svg { $0.move(30, 22); $0.line(16, 32); $0.line(10, 32); $0.line(18, 21) }, with: .color(p.mesaDark))
                ctx.fill(DesertScene.svg { $0.move(16, 11); $0.line(60, 11); $0.curve(70, 11, 78, 14, 83, 17); $0.curve(78, 20, 70, 23, 60, 23); $0.line(16, 23) },
                         with: .color(p.towerShade))
                ctx.fill(DesertScene.svg { $0.move(16, 11); $0.line(60, 11); $0.curve(70, 11, 78, 14, 83, 17); $0.line(16, 17) }, with: .color(p.towerLit))
                ctx.stroke(Path { $0.move(to: CGPoint(x: 17, y: 12)); $0.addLine(to: CGPoint(x: 62, y: 12)) }, with: .color(p.towerRim), lineWidth: 1.2)
                ctx.fill(DesertScene.svg { $0.move(66, 11.6); $0.curve(73, 12.5, 79, 14.6, 83, 17); $0.curve(79, 19.4, 73, 21.5, 66, 22.4) },
                         with: .color(p.mesaLit))
                ctx.fill(DesertScene.circle(52, 17, 3.6), with: .color(p.platUnder))
                ctx.fill(DesertScene.circle(52, 17, 2.3), with: .color(p.isNight ? p.windows : p.towerRim))
                ctx.fill(Path(CGRect(x: 13, y: 12.5, width: 4, height: 9)), with: .color(p.platUnder))
            case .ringed:
                let c = CGPoint(x: 23, y: 15)
                let ring = Path(ellipseIn: CGRect(x: c.x - 21, y: c.y - 5, width: 42, height: 10))
                var back = ctx
                back.clip(to: Path(CGRect(x: 0, y: 0, width: 46, height: c.y)))
                back.stroke(ring, with: .color(p.platTop), lineWidth: 2.2)
                ctx.fill(DesertScene.circle(c.x, c.y, 9), with: .color(p.towerLit))
                ctx.fill(DesertScene.svg { $0.move(c.x + 1, c.y - 9); $0.curve(c.x + 7, c.y - 7, c.x + 9, c.y - 3, c.x + 9, c.y)
                    $0.curve(c.x + 9, c.y + 5, c.x + 5, c.y + 9, c.x, c.y + 9); $0.curve(c.x + 5, c.y + 4, c.x + 5, c.y - 4, c.x + 1, c.y - 9) },
                         with: .color(p.towerShade))
                var front = ctx
                front.clip(to: Path(CGRect(x: 0, y: c.y, width: 46, height: 30)))
                front.stroke(ring, with: .color(p.platTop), lineWidth: 2.2)
                ctx.fill(DesertScene.circle(c.x - 3, c.y - 3, 1.4), with: .color(light))
            }
        }
    }

    /// The rocket's exhaust: a teardrop of sun colors, pointing left from the tail.
    static func drawFlame(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let flame = DesertScene.svg { $0.move(size.width, 4); $0.curve(size.width * 0.5, 4, 2, size.height * 0.35, 0, size.height / 2)
            $0.curve(2, size.height * 0.65, size.width * 0.5, size.height - 4, size.width, size.height - 4) }
        ctx.fill(flame, with: .linearGradient(Gradient(colors: [Color(rgb: 0xF98830).opacity(0), Color(rgb: 0xF98830), Color(rgb: 0xFCC477)]),
                                              startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: size.width, y: 0)))
    }

    /// A small repeatable random sequence, so the galaxy and the stars look the same every time.
    struct Seeded {
        private var state: UInt64
        init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
        /// 0..<1
        mutating func unit() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(state >> 11) / CGFloat(1 << 53)
        }
        /// -spread...spread
        mutating func next(_ spread: CGFloat) -> CGFloat { (unit() * 2 - 1) * spread }
    }
}
