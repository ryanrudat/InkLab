import SwiftUI

/// The Home header: a retro-futurist desert poster (a striped sun, a mesa, a silver city on a saucer platform,
/// a skyway), drawn as vector layers so it stays sharp at every size, keeps live text, and has a night version
/// for dark mode (navy sky, a pale moon, lit windows).
///
/// The scene lives in a 1500×460 design space. It's scaled to the header's height and anchored to the right
/// edge, so the city always shows; a wider header reveals more desert on the left, under the title.
/// Three canvases stack so only the drifting craft redraws each frame: back (sky, sun, stars, far dunes),
/// the craft, and front (towers, mesa, platform, skyway, near dunes). Far layers lag behind as the page scrolls.
struct DesertHeader: View {
    var notebookCount: Int
    /// How far the page has scrolled up, in points (0 at rest).
    var scrollOffset: CGFloat = 0

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let frame = DesertFrame(size: geo.size)
            let palette = scheme == .dark ? DesertPalette.night : .day
            let lift = max(0, scrollOffset)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in DesertScene.drawBack(&ctx, frame, palette, lift: lift) }
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                    Canvas { ctx, _ in
                        let t = reduceMotion ? nil : timeline.date.timeIntervalSinceReferenceDate
                        DesertScene.drawCraft(&ctx, frame, palette, time: t, lift: lift)
                    }
                }
                Canvas { ctx, _ in DesertScene.drawFront(&ctx, frame, palette, lift: lift) }
                title(frame, palette)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        // At night the sky is close to the page color, so a hairline steel rim keeps the poster's edge.
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.inkChrome.opacity(scheme == .dark ? 1 : 0), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("InkLab, \(countText)")
        .accessibilityAddTraits(.isHeader)
    }

    private var countText: String { notebookCount == 1 ? "1 notebook" : "\(notebookCount) notebooks" }

    private func title(_ f: DesertFrame, _ p: DesertPalette) -> some View {
        let size = min(max(70 * f.scale, 30), 52)   // Futura Bold, sized to sit clear of the mesa
        return VStack(alignment: .leading, spacing: size * 0.22) {
            Text("InkLab")
                .font(.custom("Futura-Bold", size: size))
                .foregroundStyle(p.title)
            Capsule().fill(p.underline).frame(width: size * 1.3, height: max(3, size * 0.065))
            Text(countText)
                .font(.system(size: size * 0.37, weight: .medium, design: .rounded))
                .foregroundStyle(p.subtitle)
                .padding(.top, size * 0.06)
        }
        .padding(.leading, min(max(88 * f.scale, 22), 64))
        .padding(.top, min(max(34 * f.scale, 16), 30))
    }
}

/// Maps the 1500×460 design space into the header: scale by height, anchor right.
struct DesertFrame {
    var size: CGSize
    var scale: CGFloat { size.height / 460 }
    /// Horizontal offset of the design origin (positive when the header is wider than the scene).
    var tx: CGFloat { size.width - 1500 * scale }

    /// Header height for a given width: the poster's proportions, kept within a comfortable band.
    static func height(forWidth w: CGFloat) -> CGFloat { min(max(w * 460 / 1500, 160), 330) }
}

/// Colors for the scene, day and night (sampled from the reference poster).
struct DesertPalette {
    var sky = Color.clear, sunTop = Color.clear, sunMid = Color.clear, sunLow = Color.clear
    var sunBottom = Color.clear, star = Color.clear, trail = Color.clear, craft = Color.clear
    var far = Color.clear, peach = Color.clear, peach2 = Color.clear, lightOrange = Color.clear
    var lightOrange2 = Color.clear, orange = Color.clear, orange2 = Color.clear, mesaLit = Color.clear
    var mesaMid = Color.clear, mesaDark = Color.clear, strata = Color.clear, rustMid = Color.clear
    var rustDark = Color.clear, rustMid2 = Color.clear, rustMid3 = Color.clear, rustLine = Color.clear
    var rustLine2 = Color.clear, towerLit = Color.clear, towerShade = Color.clear, towerRim = Color.clear
    var windows = Color.clear, platTop = Color.clear, platUnder = Color.clear, domeLit = Color.clear
    var domeShade = Color.clear, eyes = Color.clear, roadTop = Color.clear, roadSide = Color.clear
    var roadSide2 = Color.clear, pillarL = Color.clear, pillarR = Color.clear, title = Color.clear
    var underline = Color.clear, subtitle = Color.clear
    var isNight = false

    private init(isNight: Bool) { self.isNight = isNight }

    static let day: DesertPalette = {
        var p = DesertPalette(isNight: false)
        p.sky = Color(rgb: 0xFBEAD8)
        p.sunTop = Color(rgb: 0xF98830)
        p.sunMid = Color(rgb: 0xFDA250)
        p.sunLow = Color(rgb: 0xFFBA6D)
        p.sunBottom = Color(rgb: 0xFCC477)
        p.trail = Color(rgb: 0xC8C4C1)
        p.craft = Color(rgb: 0x1B232E)
        p.far = Color(rgb: 0xF8D2AD)
        p.peach = Color(rgb: 0xF6C597)
        p.peach2 = Color(rgb: 0xF5BF8D)
        p.lightOrange = Color(rgb: 0xF1B07E)
        p.lightOrange2 = Color(rgb: 0xF1A26B)
        p.orange = Color(rgb: 0xE98B54)
        p.orange2 = Color(rgb: 0xEA935C)
        p.mesaLit = Color(rgb: 0xE16E3C)
        p.mesaMid = Color(rgb: 0xBC512A)
        p.mesaDark = Color(rgb: 0x933B24)
        p.strata = Color(rgb: 0xEE9564)
        p.rustMid = Color(rgb: 0xBD4B26)
        p.rustDark = Color(rgb: 0x9C3A1D)
        p.rustMid2 = Color(rgb: 0xD35D33)
        p.rustMid3 = Color(rgb: 0xD67340)
        p.rustLine = Color(rgb: 0xD9693A)
        p.rustLine2 = Color(rgb: 0xB5492A)
        p.towerLit = Color(rgb: 0xCBC7C4)
        p.towerShade = Color(rgb: 0x656C77)
        p.towerRim = Color(rgb: 0xF6F4F2)
        p.platTop = Color(rgb: 0xE6E0DD)
        p.platUnder = Color(rgb: 0x70737F)
        p.domeLit = Color(rgb: 0xE9E4E1)
        p.domeShade = Color(rgb: 0xC4C1C0)
        p.eyes = Color(rgb: 0x1F232B)
        p.roadTop = Color(rgb: 0xC8B9B1)
        p.roadSide = Color(rgb: 0x21242C)
        p.roadSide2 = Color(rgb: 0x3A3E46)
        p.pillarL = Color(rgb: 0xD2C9C4)
        p.pillarR = Color(rgb: 0x8A8C93)
        p.title = Color(rgb: 0x1E2530)
        p.underline = Color(rgb: 0xE9642F)
        p.subtitle = Color(rgb: 0x85867F)
        return p
    }()

    static let night: DesertPalette = {
        var p = DesertPalette(isNight: true)
        p.sky = Color(rgb: 0x182133)
        p.sunTop = Color(rgb: 0xFDD69C)
        p.sunMid = Color(rgb: 0xFDD293)
        p.sunLow = Color(rgb: 0xFDCE87)
        p.sunBottom = Color(rgb: 0xFBC77D)
        p.star = Color(rgb: 0xE9E4D6)
        p.trail = Color(rgb: 0x6E7A8C)
        p.craft = Color(rgb: 0x3B4658)
        p.far = Color(rgb: 0x3B3038)
        p.peach = Color(rgb: 0x433236)
        p.peach2 = Color(rgb: 0x402F33)
        p.lightOrange = Color(rgb: 0x3E2D31)
        p.lightOrange2 = Color(rgb: 0x4A3030)
        p.orange = Color(rgb: 0x613630)
        p.orange2 = Color(rgb: 0x502E2C)
        p.mesaLit = Color(rgb: 0xA94B2E)
        p.mesaMid = Color(rgb: 0x7C3323)
        p.mesaDark = Color(rgb: 0x4A221D)
        p.strata = Color(rgb: 0xC2603A)
        p.rustMid = Color(rgb: 0x612A1D)
        p.rustDark = Color(rgb: 0x4B231C)
        p.rustMid2 = Color(rgb: 0x472825)
        p.rustMid3 = Color(rgb: 0x482928)
        p.rustLine = Color(rgb: 0x7A3624)
        p.rustLine2 = Color(rgb: 0x5E2A1E)
        p.towerLit = Color(rgb: 0x76808F)
        p.towerShade = Color(rgb: 0x465062)
        p.towerRim = Color(rgb: 0xA9AEB5)
        p.windows = Color(rgb: 0xF4C26B)
        p.platTop = Color(rgb: 0xA6A6AB)
        p.platUnder = Color(rgb: 0x2E3542)
        p.domeLit = Color(rgb: 0x8F929B)
        p.domeShade = Color(rgb: 0x5C6573)
        p.eyes = Color(rgb: 0xF4C26B)
        p.roadTop = Color(rgb: 0x3A414C)
        p.roadSide = Color(rgb: 0x141920)
        p.roadSide2 = Color(rgb: 0x232A33)
        p.pillarL = Color(rgb: 0x5A6270)
        p.pillarR = Color(rgb: 0x333A46)
        p.title = Color(rgb: 0xF4EAD7)
        p.underline = Color(rgb: 0xED9B50)
        p.subtitle = Color(rgb: 0xA8B0BB)
        return p
    }()
}

/// The scene's shapes, in design units.
enum DesertScene {
    // MARK: Layers

    static func drawBack(_ ctx: inout GraphicsContext, _ f: DesertFrame, _ p: DesertPalette, lift: CGFloat) {
        let c = designContext(ctx, f, lift: 0)
        c.fill(Path(CGRect(x: -4000, y: -200, width: 5600, height: 900)), with: .color(p.sky))

        let far = designContext(ctx, f, lift: lift * 0.4)
        if p.isNight {
            for (x, y, r) in stars { far.fill(circle(x, y, r), with: .color(p.star)) }
        }
        // Sun (moon at night), its lower part cut away by widening stripes in the sky color.
        let sun: (x: CGFloat, y: CGFloat, r: CGFloat, cut: CGFloat) = p.isNight ? (1166, 150, 97, 251) : (1158, 162, 127, 268)
        let stripes: [(CGFloat, CGFloat)] = p.isNight ? [(192, 3), (221, 4), (246, 5)]
                                                    : [(182, 4), (203, 4), (221, 5), (239, 6), (256, 7)]
        var disc = far
        disc.clip(to: Path(CGRect(x: 0, y: -100, width: 1500, height: sun.cut + 100)))
        disc.fill(circle(sun.x, sun.y, sun.r), with: .linearGradient(
            Gradient(stops: [.init(color: p.sunTop, location: 0), .init(color: p.sunMid, location: 0.55),
                             .init(color: p.sunLow, location: 0.85), .init(color: p.sunBottom, location: 1)]),
            startPoint: CGPoint(x: 0, y: sun.y - sun.r), endPoint: CGPoint(x: 0, y: sun.cut)))
        for (y, h) in stripes {
            far.fill(Path(CGRect(x: sun.x - sun.r - 2, y: y, width: 2 * sun.r + 4, height: h)), with: .color(p.sky))
        }

        let dunes = designContext(ctx, f, lift: lift * 0.3)
        dunes.fill(ground([(0, 294), (60, 289), (150, 299), (210, 308), (265, 297), (330, 304), (450, 300), (560, 292),
                           (708, 291), (790, 281), (835, 277), (880, 284), (915, 293), (1000, 300), (1200, 302),
                           (1360, 303), (1400, 291), (1440, 292), (1500, 297)]), with: .color(p.far))
        dunes.fill(ground([(0, 342), (40, 334), (90, 328), (140, 322), (190, 316), (232, 305), (300, 303), (360, 312),
                           (540, 312), (600, 312), (700, 320), (900, 318), (1200, 314), (1350, 307), (1420, 306),
                           (1500, 309)]), with: .color(p.peach))
    }

    /// The craft drifts left to right across the sky (behind the city) once every 48 s; static when
    /// Reduce Motion is on (`time == nil`).
    static func drawCraft(_ ctx: inout GraphicsContext, _ f: DesertFrame, _ p: DesertPalette, time: TimeInterval?, lift: CGFloat) {
        let c = designContext(ctx, f, lift: lift * 0.4)
        var x: CGFloat = 780, y: CGFloat = 85
        if let time {
            let period = 48.0
            let phase = (time.truncatingRemainder(dividingBy: period)) / period
            // Start off the left edge of whatever is visible, end past the right edge.
            let start = -f.tx / f.scale - 120
            x = start + CGFloat(phase) * (1640 - start)
            y = 85 + 5 * CGFloat(sin(time * 2 * .pi / 9))
        }
        let trail = Path { $0.move(to: CGPoint(x: x - 90, y: y + 7.5)); $0.addLine(to: CGPoint(x: x - 14, y: y + 1.5)) }
        c.stroke(trail, with: .linearGradient(Gradient(colors: [p.trail.opacity(0), p.trail]),
                                              startPoint: CGPoint(x: x - 90, y: 0), endPoint: CGPoint(x: x - 12, y: 0)),
                 style: StrokeStyle(lineWidth: 3, lineCap: .round))
        c.fill(Path(ellipseIn: CGRect(x: x - 16, y: y - 5, width: 32, height: 10)), with: .color(p.craft))
        if p.isNight { c.fill(circle(x + 11, y, 1.8), with: .color(p.windows)) }
    }

    static func drawFront(_ ctx: inout GraphicsContext, _ f: DesertFrame, _ p: DesertPalette, lift: CGFloat) {
        var mid = designContext(ctx, f, lift: lift * 0.15)
        drawTowers(&mid, p)
        drawMesa(&mid, p)

        mid.fill(ground([(540, 352), (590, 328), (650, 314), (705, 318), (760, 330), (820, 346), (900, 356)]), with: .color(p.lightOrange))
        mid.fill(ground([(0, 360), (60, 345), (110, 335), (150, 332), (200, 338), (250, 352), (290, 368)]), with: .color(p.lightOrange))
        mid.fill(ground([(200, 392), (250, 372), (300, 354), (360, 346), (430, 344), (500, 346), (560, 352), (620, 360),
                         (700, 368), (780, 372), (860, 376), (1000, 386)]), with: .color(p.orange))
        mid.fill(ground([(330, 400), (400, 372), (470, 360), (540, 362), (620, 372), (700, 382), (800, 392), (900, 400)]), with: .color(p.lightOrange))
        mid.fill(ground([(700, 386), (800, 378), (900, 372), (1000, 370), (1200, 368), (1350, 360), (1500, 356)]), with: .color(p.peach2))
        drawPlatform(&mid, p)

        var near = designContext(ctx, f, lift: 0)
        near.fill(ground([(0, 372), (40, 366), (100, 361), (160, 364), (220, 375), (262, 386), (300, 396), (340, 410),
                          (380, 430), (420, 460)]), with: .color(p.rustMid))
        near.fill(ground([(0, 412), (60, 400), (120, 394), (180, 393), (230, 397), (280, 407), (320, 420), (350, 434),
                          (380, 460)]), with: .color(p.rustDark))
        var lines = near
        lines.opacity = 0.65
        lines.stroke(smooth([(30, 384), (100, 374), (170, 378), (230, 390)]), with: .color(p.rustLine), lineWidth: 2)
        lines.stroke(smooth([(20, 430), (100, 416), (190, 414), (260, 426)]), with: .color(p.rustLine2), lineWidth: 2)
        drawSkyway(&near, p)
        near.fill(ground([(560, 460), (600, 450), (650, 446), (700, 448), (740, 456), (760, 460)]), with: .color(p.rustMid2))
        near.fill(ground([(640, 460), (700, 444), (780, 436), (860, 434), (960, 436), (1060, 440), (1140, 446), (1200, 452),
                          (1240, 460)]), with: .color(p.lightOrange2))
        near.fill(ground([(1150, 460), (1200, 430), (1260, 420), (1330, 418), (1390, 408), (1450, 404), (1500, 404)]), with: .color(p.orange2))
        near.fill(ground([(1180, 460), (1220, 446), (1290, 438), (1360, 440), (1400, 452), (1420, 460)]), with: .color(p.rustMid3))
    }

    // MARK: Pieces

    private static let towerBase: CGFloat = 345

    private static func drawTowers(_ c: inout GraphicsContext, _ p: DesertPalette) {
        let b = towerBase
        tower(&c, p, 940, 970, 174, antenna: 112, antennaWidth: 3, windows: [(8, 230), (8, 262)])
        tower(&c, p, 975, 998, 222, windows: [(9, 270)])
        tower(&c, p, 1000, 1035, 64, antenna: 16, windows: [(12, 120), (12, 170), (12, 220)])
        // a small fin, shaded, with a lit edge
        c.fill(svg { $0.move(1045, b); $0.line(1045, 254); $0.curve(1058, 256, 1068, 266, 1074, 286); $0.line(1074, b) }, with: .color(p.towerShade))
        c.fill(svg { $0.move(1068, 270); $0.curve(1071, 276, 1073, 281, 1074, 286); $0.line(1074, b); $0.line(1068, b) }, with: .color(p.towerLit))
        tower(&c, p, 1090, 1168, 32, ogive: 1.2, split: 0.5, windows: [(22, 110), (22, 170), (44, 140), (44, 215)])
        tower(&c, p, 1185, 1203, 278)
        tower(&c, p, 1205, 1228, 158, antenna: 100, windows: [(9, 200), (9, 250)])
        // a fin rising to the right
        c.fill(svg { $0.move(1250, b); $0.line(1250, 262); $0.curve(1258, 244, 1272, 232, 1290, 228); $0.line(1290, b) }, with: .color(p.towerShade))
        c.fill(svg { $0.move(1250, b); $0.line(1250, 262); $0.curve(1256, 250, 1262, 243, 1270, 238); $0.line(1270, b) }, with: .color(p.towerLit))
        c.fill(svg { $0.move(1288, 229); $0.line(1290, 228); $0.line(1290, b); $0.line(1287, b) }, with: .color(p.towerRim))
        tower(&c, p, 1295, 1312, 284)
        // a blade with a straight lit edge
        c.fill(svg { $0.move(1320, b); $0.line(1320, 162); $0.curve(1332, 172, 1342, 192, 1342, 222); $0.line(1342, b) }, with: .color(p.towerShade))
        c.fill(svg { $0.move(1320, b); $0.line(1320, 162); $0.curve(1325, 168, 1329, 174, 1331, 182); $0.line(1331, b) }, with: .color(p.towerLit))
        if p.isNight {
            for (x, y) in [(1327.0, 250.0), (1262, 280)] as [(CGFloat, CGFloat)] { window(&c, p, x, y) }
        }
    }

    /// A bullet tower: straight sides and an ogive top, lit on the left with a bright rim, shaded on the right.
    private static func tower(_ c: inout GraphicsContext, _ p: DesertPalette, _ x0: CGFloat, _ x1: CGFloat, _ top: CGFloat,
                              ogive: CGFloat = 1.25, split: CGFloat = 0.48, antenna: CGFloat? = nil, antennaWidth: CGFloat = 2.5,
                              windows: [(CGFloat, CGFloat)] = []) {
        let base = towerBase, w = x1 - x0, cx = x0 + w / 2, shoulder = top + w * ogive, sx = x0 + w * split
        if let antenna {
            c.stroke(Path { $0.move(to: CGPoint(x: cx, y: antenna)); $0.addLine(to: CGPoint(x: cx, y: top + 2)) },
                     with: .color(p.towerShade), style: StrokeStyle(lineWidth: antennaWidth, lineCap: .round))
        }
        c.fill(svg {
            $0.move(x0, base); $0.line(x0, shoulder); $0.curve(x0, top + w * 0.35, cx - w * 0.12, top + 2, cx, top)
            $0.curve(cx + w * 0.12, top + 2, x1, top + w * 0.35, x1, shoulder); $0.line(x1, base)
        }, with: .color(p.towerLit))
        c.fill(svg {
            $0.move(sx, base); $0.line(sx, shoulder); $0.curve(sx, top + w * 0.5, cx, top + 6, cx, top)
            $0.curve(cx + w * 0.12, top + 2, x1, top + w * 0.35, x1, shoulder); $0.line(x1, base)
        }, with: .color(p.towerShade))
        let rim = Path { path in
            path.move(to: CGPoint(x: x0 + 1.2, y: base)); path.addLine(to: CGPoint(x: x0 + 1.2, y: shoulder))
            path.addCurve(to: CGPoint(x: cx, y: top + 1), control1: CGPoint(x: x0 + 1.2, y: top + w * 0.4),
                          control2: CGPoint(x: cx - w * 0.15, y: top + 6))
        }
        c.stroke(rim, with: .color(p.towerRim), lineWidth: 2.2)
        if p.isNight { for (dx, y) in windows { window(&c, p, x0 + dx, y) } }
    }

    private static func window(_ c: inout GraphicsContext, _ p: DesertPalette, _ x: CGFloat, _ y: CGFloat) {
        c.fill(Path(roundedRect: CGRect(x: x, y: y, width: 4, height: 6), cornerRadius: 1), with: .color(p.windows))
    }

    private static func drawMesa(_ c: inout GraphicsContext, _ p: DesertPalette) {
        let outline: [(CGFloat, CGFloat)] = [
            (232, 372), (258, 352), (276, 340), (288, 328), (306, 316), (318, 304), (334, 292), (342, 274), (354, 256),
            (365, 238), (372, 220), (378, 202), (385, 184), (391, 166), (402, 148), (424, 132), (444, 121), (462, 116),
            (478, 118), (489, 125), (495, 134), (498, 148), (504, 166), (510, 184), (517, 202), (527, 220), (534, 238),
            (540, 256), (546, 274), (553, 292), (564, 304), (577, 316), (592, 328), (602, 342), (614, 358), (640, 370), (700, 380),
        ]
        var shape = smooth(outline)
        shape.closeSubpath()
        c.fill(shape, with: .linearGradient(
            Gradient(stops: [.init(color: p.mesaLit, location: 0), .init(color: p.mesaLit, location: 0.32),
                             .init(color: p.mesaMid, location: 0.52), .init(color: p.mesaDark, location: 0.66),
                             .init(color: p.mesaDark, location: 1)]),
            startPoint: CGPoint(x: 300, y: 0), endPoint: CGPoint(x: 600, y: 40)))
        var strata = c
        strata.opacity = 0.85
        for line in [[(372.0, 262.0), (402, 236), (438, 212), (474, 190), (500, 176)],
                     [(350, 300), (384, 276), (424, 252), (466, 230), (504, 216)],
                     [(332, 326), (372, 306), (418, 286), (462, 268), (500, 258)],
                     [(404, 196), (430, 176), (460, 158), (486, 146)]] as [[(CGFloat, CGFloat)]] {
            strata.stroke(smooth(line), with: .color(p.strata), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }
    }

    private static func drawPlatform(_ c: inout GraphicsContext, _ p: DesertPalette) {
        c.fill(Path(ellipseIn: CGRect(x: 1030 - 318, y: 358 - 16, width: 636, height: 32)), with: .color(p.platUnder))
        c.fill(Path(ellipseIn: CGRect(x: 1030 - 318, y: 337 - 19, width: 636, height: 38)), with: .color(p.platTop))
        c.fill(svg {
            $0.move(712, 337); $0.curve(760, 349, 880, 356, 1030, 356); $0.curve(1180, 356, 1300, 349, 1348, 337)
            $0.curve(1348, 345, 1346, 350, 1340, 352); $0.curve(1290, 366, 1170, 374, 1030, 374)
            $0.curve(890, 374, 770, 366, 720, 352); $0.curve(714, 348, 712, 343, 712, 337)
        }, with: .color(p.platUnder))
        c.fill(svg { $0.move(905, 326); $0.curve(914, 300, 958, 281, 1004, 281); $0.curve(1050, 281, 1092, 300, 1101, 326) },
               with: .color(p.domeLit))
        c.fill(svg { $0.move(1040, 285); $0.curve(1072, 292, 1094, 306, 1101, 326); $0.line(1052, 326); $0.curve(1058, 312, 1054, 296, 1040, 285) },
               with: .color(p.domeShade))
        c.fill(circle(988, 313, 4.6), with: .color(p.eyes))
        c.fill(circle(1012, 313, 4.6), with: .color(p.eyes))
        if p.isNight {
            for x in [760.0, 830, 900, 1170, 1240, 1310] as [CGFloat] {
                c.fill(circle(x, 351 - abs(x - 1030) * 0.012, 2), with: .color(p.windows))
            }
        }
    }

    private static func drawSkyway(_ c: inout GraphicsContext, _ p: DesertPalette) {
        for (x0, y0) in [(1180.0, 376.0), (900, 390)] as [(CGFloat, CGFloat)] {
            let path = svg {
                $0.move(x0, y0); $0.curve(x0 + 18, y0 + 4, x0 + 26, y0 + 10, x0 + 28, y0 + 22); $0.line(x0 + 26, 460)
                $0.line(x0 + 52, 460); $0.line(x0 + 50, y0 + 22); $0.curve(x0 + 52, y0 + 10, x0 + 60, y0 + 4, x0 + 72, y0)
            }
            c.fill(path, with: .linearGradient(Gradient(colors: [p.pillarL, p.pillarR]),
                                               startPoint: CGPoint(x: x0 + 20, y: 0), endPoint: CGPoint(x: x0 + 56, y: 0)))
        }
        let top: [(CGFloat, CGFloat)] = [(1500, 352), (1350, 356), (1200, 362), (1050, 372), (940, 381), (840, 391), (760, 400),
                                         (690, 410), (630, 420), (585, 430), (548, 442), (520, 452), (500, 460)]
        let side: [(CGFloat, CGFloat)] = [(1500, 358), (1350, 362), (1200, 368), (1050, 378), (940, 387), (840, 397), (760, 406),
                                          (692, 416), (636, 427), (596, 437), (566, 448), (546, 460)]
        let bottom: [(CGFloat, CGFloat)] = [(575, 460), (585, 456), (612, 448), (652, 438), (700, 428), (760, 418), (840, 407),
                                            (940, 396), (1050, 387), (1200, 377), (1350, 371), (1500, 368)]
        func band(_ upper: [(CGFloat, CGFloat)]) -> Path {
            var path = smooth(upper)
            appendSmooth(&path, bottom)
            path.closeSubpath()
            return path
        }
        c.fill(band(top), with: .color(p.roadTop))
        c.fill(band(side), with: .linearGradient(Gradient(colors: [p.roadSide, p.roadSide2]),
                                                 startPoint: CGPoint(x: 500, y: 0), endPoint: CGPoint(x: 1500, y: 0)))
        if p.isNight {
            for i in [1, 3, 5, 7, 9] { c.fill(circle(side[i].0, side[i].1 + 4, 2.2), with: .color(p.windows)) }
        }
    }

    private static let stars: [(CGFloat, CGFloat, CGFloat)] = [
        (698, 41, 1.6), (372, 59, 1.4), (1386, 65, 1.8), (894, 101, 1.3), (560, 107, 1.5), (1450, 199, 1.6), (652, 209, 1.2),
        (176, 245, 1.4), (260, 28, 1.2), (1300, 140, 1.1), (1470, 40, 1.3), (470, 40, 1.1), (40, 120, 1.2), (-160, 70, 1.4),
        (-320, 180, 1.2), (-480, 50, 1.5),
    ]

    // MARK: Geometry helpers

    /// A context that draws in design units, nudged down by `lift` points (parallax: far layers lag the scroll).
    private static func designContext(_ ctx: GraphicsContext, _ f: DesertFrame, lift: CGFloat) -> GraphicsContext {
        var c = ctx
        c.translateBy(x: f.tx, y: lift)
        c.scaleBy(x: f.scale, y: f.scale)
        return c
    }

    private static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }

    /// A smooth curve through the points (Catmull-Rom as cubic Béziers).
    static func smooth(_ pts: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: CGPoint(x: first.0, y: first.1))
        appendCurves(&path, pts)
        return path
    }

    /// Continues `path` with a line to the first point, then a smooth curve through the rest.
    static func appendSmooth(_ path: inout Path, _ pts: [(CGFloat, CGFloat)]) {
        guard let first = pts.first else { return }
        path.addLine(to: CGPoint(x: first.0, y: first.1))
        appendCurves(&path, pts)
    }

    private static func appendCurves(_ path: inout Path, _ pts: [(CGFloat, CGFloat)]) {
        guard pts.count > 1 else { return }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            path.addCurve(to: CGPoint(x: p2.0, y: p2.1),
                          control1: CGPoint(x: p1.0 + (p2.0 - p0.0) / 6, y: p1.1 + (p2.1 - p0.1) / 6),
                          control2: CGPoint(x: p2.0 - (p3.0 - p1.0) / 6, y: p2.1 - (p3.1 - p1.1) / 6))
        }
    }

    /// A dune: a smooth top edge filled down to the bottom. Layers that start at the left edge are extended
    /// flat far to the left, so a header wider than the scene shows more desert instead of a gap.
    private static func ground(_ pts: [(CGFloat, CGFloat)]) -> Path {
        var path = smooth(pts)
        path.addLine(to: CGPoint(x: 1500, y: 470))
        if pts[0].0 <= 0 {
            path.addLine(to: CGPoint(x: -4000, y: 470))
            path.addLine(to: CGPoint(x: -4000, y: pts[0].1))
        } else {
            path.addLine(to: CGPoint(x: 0, y: 470))   // closes back up to the first point, under the nearer layers
        }
        path.closeSubpath()
        return path
    }

    /// Builds a closed path from SVG-like commands in design units.
    private static func svg(_ build: (inout PathBuilder) -> Void) -> Path {
        var b = PathBuilder()
        build(&b)
        b.path.closeSubpath()
        return b.path
    }

    struct PathBuilder {
        var path = Path()
        mutating func move(_ x: CGFloat, _ y: CGFloat) { path.move(to: CGPoint(x: x, y: y)) }
        mutating func line(_ x: CGFloat, _ y: CGFloat) { path.addLine(to: CGPoint(x: x, y: y)) }
        mutating func curve(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat, _ y: CGFloat) {
            path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
        }
    }
}

#Preview("Day") { DesertHeader(notebookCount: 3).frame(width: 1100, height: 330).padding() }
#Preview("Night") { DesertHeader(notebookCount: 3).frame(width: 1100, height: 330).padding().preferredColorScheme(.dark) }
