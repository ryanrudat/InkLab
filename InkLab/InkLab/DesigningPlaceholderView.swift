import SwiftUI
import UIKit

/// A transient "Designing…" card shown on the canvas exactly where a make-real widget will land, while
/// generation runs in the background. It is NOT a journal object: purely visual, not persisted, not
/// interactive; the host removes it and drops the real widget in its place when the generation finishes (or
/// removes it on failure).
///
/// It is the Home header's poster, framed for a card, passing from day to night and back while the work goes
/// on: the striped sun sets behind the dunes as the night poster fades in (navy sky, stars, lit windows), the
/// moon rises and sets, and day comes back as the sun rises. A hazy galaxy turns slowly in the tall sky, craft
/// of different kinds cross it at their own pace, and lights run along the skyway. The title block echoes
/// Home's ("InkLab" in Futura Bold over a sun-orange rule). The cycle starts on the app's own appearance, day
/// in light mode and night in dark mode; under Reduce Motion it holds still on that one.
/// Everything is drawn once into images (a day and a night copy of each layer) and moved by Core Animation.
final class DesigningPlaceholderView: UIView {
    /// The page the widget will land on. The overlay is shared by every page, so the host hides this card
    /// while another page is showing.
    let pageID: UUID
    /// Where the card's window onto the Home scene starts (design units): the platform, the city and the sun.
    static let sceneFromX: CGFloat = 860
    /// How far the sun (and the moon) sinks to be fully down behind the dunes (design units).
    static let setDrop: CGFloat = 290
    /// The Home poster's striped mesa, moved right (design units) so it rises at the card's right edge, behind
    /// the city and in front of the setting sun.
    static let mesaShift: CGFloat = 1000
    /// One day and one night, in seconds.
    static let cycle: CFTimeInterval = 24
    /// Where in the cycle night is fully in (a fraction of it): a card shown in dark mode starts here.
    static let nightStart: Double = 0.58

    /// The cycle, as fractions of it: how much of the night poster shows, and how far down the sun and the moon
    /// are (0 up, 1 set). Day rests with the sun high and its stripes showing; the sun sets as night fades in and
    /// the moon rises; night rests; the moon sets as day fades back and the sun rises.
    enum Cycle {
        static let night: (values: [Double], times: [Double]) = ([0, 0, 1, 1, 0, 0], [0, 0.30, 0.45, 0.78, 0.92, 1])
        static let sun: (values: [Double], times: [Double]) = ([0, 0, 1, 1, 0], [0, 0.20, 0.40, 0.84, 1])
        static let moon: (values: [Double], times: [Double]) = ([1, 1, 0, 0, 1, 1], [0, 0.40, 0.56, 0.70, 0.84, 1])
        /// The glow comes up as the sun sets and stays until night covers it; at dawn it shows as night fades and
        /// goes as day comes back.
        static let dusk: (values: [Double], times: [Double]) = ([0, 0, 1, 1, 0, 0, 1, 1, 0, 0],
                                                                [0, 0.22, 0.33, 0.46, 0.50, 0.74, 0.78, 0.86, 0.95, 1])
        /// The title's night ink: it comes in quickly with the sunset glow (dark violet overhead) and goes quickly
        /// as the glow does, so it's never long half one ink and half the other.
        static let ink: (values: [Double], times: [Double]) = ([0, 0, 1, 1, 0, 0], [0, 0.26, 0.33, 0.86, 0.90, 1])
    }

    /// Clips the poster to the card's corners (the card itself can't clip, or it would lose its shadow).
    private let poster = UIView()
    /// Each layer of the scene in a day copy and a night copy, the night one over the day one.
    private struct Pair { let day = CALayer(), night = CALayer() }
    private let sky = Pair(), farDunes = Pair(), front = Pair(), galaxyArt = Pair()
    private let galaxyTilt = CALayer(), galaxySpin = CALayer(), sun = CALayer(), moon = CALayer(), craftLayer = CALayer()
    /// The sunset (and sunrise) sky, between the day sky and the night one, so the change passes through a
    /// warm glow instead of a gray mix of the two.
    private let dusk = CALayer()
    /// Three dots after the title that pulse in turn while it works (they don't move, so they stay under
    /// Reduce Motion).
    private var titleDots: [CALayer] = []
    private(set) var craftRigs: [CALayer] = []
    private(set) var skywayLights: [CALayer] = []
    /// Every layer that shows only at night (it fades with the cycle).
    private(set) var nightLayers: [CALayer] = []
    private var twinkles: [CALayer] = []
    /// The title block in day and night ink (each reads on its own sky), cross-faded with the cycle.
    private let titleDay = UILabel(), titleNight = UILabel(), promptDay = UILabel(), promptNight = UILabel()
    private let underline = UIView()
    private var baseTitle = "Designing"
    /// What the images were last drawn for (a new size draws them again; the appearance sets where the cycle starts).
    private var builtFor: (size: CGSize, dark: Bool)?
    private var stopped = false

    init(prompt: String, pageID: UUID, frame: CGRect) {
        self.pageID = pageID
        super.init(frame: frame)
        isUserInteractionEnabled = false           // taps pass through to the canvas
        isAccessibilityElement = true
        accessibilityLabel = "Designing “\(prompt)”"
        backgroundColor = Theme.card
        Theme.styleCard(layer)
        layer.shadowColor = UIColor(red: 0.30, green: 0.18, blue: 0.10, alpha: 1).cgColor
        layer.shadowOpacity = 0.14
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 5)

        poster.isUserInteractionEnabled = false
        poster.clipsToBounds = true
        poster.layer.cornerRadius = Theme.cardRadius
        poster.layer.cornerCurve = .continuous
        addSubview(poster)
        // Back to front: sky, galaxy, sun and moon, the far dunes they set behind, the craft, the city.
        for l in [sky.day, dusk, sky.night, galaxyTilt, sun, moon, farDunes.day, farDunes.night, craftLayer, front.day, front.night] {
            poster.layer.addSublayer(l)
        }
        galaxyTilt.addSublayer(galaxySpin)
        galaxySpin.addSublayer(galaxyArt.day)
        galaxySpin.addSublayer(galaxyArt.night)

        for label in [titleDay, titleNight] {
            label.text = baseTitle
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.7
        }
        underline.layer.cornerCurve = .continuous
        for label in [promptDay, promptNight] {
            label.text = "“\(prompt)”"
            label.numberOfLines = 2
        }
        for v in [titleDay, titleNight, underline, promptDay, promptNight] { poster.addSubview(v) }   // above the scene

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: DesigningPlaceholderView, _: UITraitCollection) in
            self.builtFor = nil
            self.layer.borderColor = Theme.chrome.cgColor
            self.setNeedsLayout()
        }
        startDots()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        poster.frame = bounds
        let dark = traitCollection.userInterfaceStyle == .dark
        guard bounds.width > 1, bounds.height > 1, builtFor?.size != bounds.size || builtFor?.dark != dark else { return }
        builtFor = (bounds.size, dark)
        build(startAtNight: dark)
    }

    // MARK: Building the poster

    private func build(startAtNight: Bool) {
        let size = bounds.size
        let f = DesertFrame(card: size, fromX: Self.sceneFromX)
        let scale = max(1, traitCollection.displayScale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for l in [sky.day, dusk, sky.night, sun, moon, farDunes.day, farDunes.night, front.day, front.night] {
            l.frame = bounds
            l.contentsScale = scale
        }
        craftLayer.frame = bounds
        for (layer, p) in [(sky.day, DesertPalette.day), (sky.night, .night)] {
            layer.contents = DesigningArt.image(size, scale: scale) { ctx, sz in
                DesertScene.drawSky(&ctx, f, p, lift: 0)
                guard p.isNight else { return }
                for s in DesigningArt.cardStars {
                    ctx.fill(DesertScene.circle(s.x * sz.width, s.y * sz.height, s.r), with: .color(p.star.opacity(0.85)))
                }
            }
        }
        dusk.contents = DesigningArt.image(size, scale: scale) { ctx, sz in
            // A poster sunset: violet overhead, rose in the middle, gold low over the desert.
            let horizon = f.ty + 300 * f.scale
            ctx.fill(Path(CGRect(origin: .zero, size: sz)), with: .linearGradient(
                Gradient(stops: [.init(color: Color(rgb: 0x3E3656), location: 0), .init(color: Color(rgb: 0x8E4E64), location: 0.45),
                                 .init(color: Color(rgb: 0xD9785A), location: 0.8), .init(color: Color(rgb: 0xF2A65A), location: 1)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: horizon)))
        }
        sun.contents = DesigningArt.image(size, scale: scale) { ctx, _ in DesertScene.drawSun(&ctx, f, .day, lift: 0, cutOut: true) }
        moon.contents = DesigningArt.image(size, scale: scale) { ctx, _ in DesertScene.drawSun(&ctx, f, .night, lift: 0, cutOut: true) }
        for (layer, p) in [(farDunes.day, DesertPalette.day), (farDunes.night, .night)] {
            layer.contents = DesigningArt.image(size, scale: scale) { ctx, _ in
                DesertScene.drawFarDunes(&ctx, f, p, lift: 0)
                var mesa = DesertScene.designContext(ctx, f, lift: 0)
                mesa.translateBy(x: Self.mesaShift, y: 0)
                DesertScene.drawMesa(&mesa, p)
            }
        }
        for (layer, p) in [(front.day, DesertPalette.day), (front.night, .night)] {
            layer.contents = DesigningArt.image(size, scale: scale) { ctx, _ in DesertScene.drawFront(&ctx, f, p, lift: 0) }
        }

        layoutTitle(width: size.width)
        let skyTop = promptDay.frame.maxY + 14                   // under the title block
        let skyline = f.ty + 40 * f.scale                         // the tops of the towers and the sun
        let band = max(60, skyline - skyTop)

        // The galaxy: a face-on spiral squashed and tilted into a disc seen at an angle; it turns inside that.
        let g = min(size.width * 0.8, 320)
        galaxyTilt.bounds = CGRect(x: 0, y: 0, width: g, height: g)
        galaxyTilt.position = CGPoint(x: size.width * 0.6, y: skyTop + band * 0.5)
        galaxyTilt.transform = CATransform3DConcat(CATransform3DMakeScale(1, 0.46, 1), CATransform3DMakeRotation(-0.42, 0, 0, 1))
        galaxySpin.frame = galaxyTilt.bounds
        for (layer, p) in [(galaxyArt.day, DesertPalette.day), (galaxyArt.night, .night)] {
            layer.frame = galaxyTilt.bounds
            layer.contentsScale = scale
            layer.contents = DesigningArt.image(CGSize(width: g, height: g), scale: scale) { ctx, sz in DesigningArt.drawGalaxy(&ctx, sz, p) }
        }

        nightLayers = [sky.night, farDunes.night, front.night, galaxyArt.night, moon]
        buildCraft(scale: scale, width: size.width, skyTop: skyTop, band: band)
        buildLights(f)
        buildTwinkles(size: size)

        // Held still (Reduce Motion, or once stopped), the card shows the app's own appearance.
        for l in nightLayers + [titleNight.layer, promptNight.layer] { l.opacity = startAtNight ? 1 : 0 }
        for l in [titleDay.layer, promptDay.layer] { l.opacity = startAtNight ? 0 : 1 }
        dusk.opacity = 0
        sun.transform = CATransform3DMakeTranslation(0, startAtNight ? Self.setDrop * f.scale : 0, 0)
        moon.transform = CATransform3DMakeTranslation(0, startAtNight ? 0 : Self.setDrop * f.scale, 0)
        underline.backgroundColor = UIColor(startAtNight ? DesertPalette.night.underline : DesertPalette.day.underline)
        for dot in titleDots { dot.backgroundColor = underline.backgroundColor?.cgColor }
        animate(f: f, startAtNight: startAtNight)
    }

    private func layoutTitle(width: CGFloat) {
        let size = min(28, max(20, width * 0.072))
        let inset = max(18, width * 0.06)
        for (label, p) in [(titleDay, DesertPalette.day), (titleNight, .night)] {
            label.font = Theme.title(size, bold: true)
            label.textColor = UIColor(p.title)
            label.frame = CGRect(x: inset, y: inset, width: width - 2 * inset, height: ceil(size * 1.25))
        }
        placeTitleDots()
        let rule = max(3, size * 0.065)
        underline.frame = CGRect(x: inset, y: titleDay.frame.maxY + size * 0.12, width: size * 1.3, height: rule)
        underline.layer.cornerRadius = rule / 2
        for (label, p) in [(promptDay, DesertPalette.day), (promptNight, .night)] {
            label.font = Theme.ui(size * 0.5, .medium)
            label.textColor = UIColor(p.subtitle)
            let fit = label.sizeThatFits(CGSize(width: width - 2 * inset, height: .greatestFiniteMagnitude))
            label.frame = CGRect(x: inset, y: underline.frame.maxY + size * 0.3, width: width - 2 * inset,
                                 height: min(ceil(fit.height), ceil(label.font.lineHeight * 2 + 2)))
        }
    }

    /// One craft's flight across the card: where it starts and ends, how long a crossing takes, how far into
    /// its first crossing it starts (so they don't all appear at once), how big it is, and its bob.
    private struct Flight {
        var craft: DesigningArt.Craft
        var from: CGPoint, to: CGPoint
        var duration: CFTimeInterval, head: Double
        var size: CGFloat, bob: CGFloat, bobPeriod: CFTimeInterval
        /// Where it sits when nothing moves (Reduce Motion), as a fraction of the way across.
        var still: CGFloat
    }

    private var flights: [Flight] = []

    private func buildCraft(scale: CGFloat, width w: CGFloat, skyTop: CGFloat, band: CGFloat) {
        craftRigs.forEach { $0.removeFromSuperlayer() }
        craftRigs = []
        flights = [
            Flight(craft: .ringed, from: CGPoint(x: w + 40, y: skyTop + band * 0.08), to: CGPoint(x: -40, y: skyTop + band * 0.16),
                   duration: 58, head: 0.35, size: 0.95, bob: 2, bobPeriod: 7, still: 0.22),
            Flight(craft: .cigar, from: CGPoint(x: -140, y: skyTop + band * 0.36), to: CGPoint(x: w + 70, y: skyTop + band * 0.30),
                   duration: 26, head: 0.6, size: 0.9, bob: 4, bobPeriod: 9, still: 0.74),
            Flight(craft: .saucer, from: CGPoint(x: w + 50, y: skyTop + band * 0.82), to: CGPoint(x: -50, y: skyTop + band * 0.76),
                   duration: 34, head: 0.12, size: 0.85, bob: 3.5, bobPeriod: 2.6, still: 0.68),
            Flight(craft: .rocket, from: CGPoint(x: -70, y: skyTop + band * 0.98), to: CGPoint(x: w + 70, y: skyTop + band * 0.06),
                   duration: 40, head: 0.8, size: 0.8, bob: 0, bobPeriod: 1, still: 0.3),
        ]
        for flight in flights {
            let rig = CALayer()
            let art = flight.craft.size
            rig.bounds = CGRect(origin: .zero, size: CGSize(width: art.width * flight.size, height: art.height * flight.size))
            let body = CALayer()
            body.frame = rig.bounds
            body.name = "body"
            rig.addSublayer(body)
            if flight.craft == .rocket {
                let flame = CALayer()
                let fs = CGSize(width: 22 * flight.size, height: 12 * flight.size)
                flame.anchorPoint = CGPoint(x: 1, y: 0.5)             // flickers out from the tail
                flame.bounds = CGRect(origin: .zero, size: fs)
                flame.position = CGPoint(x: 13 * flight.size, y: 17 * flight.size)
                flame.contentsScale = scale
                flame.contents = DesigningArt.image(fs, scale: scale) { ctx, sz in DesigningArt.drawFlame(&ctx, sz) }
                flame.name = "flame"
                body.addSublayer(flame)
            }
            // The craft in day and night colors (lit windows at night), the night one over the day one.
            for p in [DesertPalette.day, .night] {
                let look = CALayer()
                look.frame = body.bounds
                look.contentsScale = scale
                look.contents = DesigningArt.image(art, scale: scale * flight.size) { ctx, _ in flight.craft.draw(&ctx, p) }
                body.addSublayer(look)
                if p.isNight { nightLayers.append(look) }
            }
            // Flown the other way, it's mirrored; the rocket climbs along its path.
            let dx = flight.to.x - flight.from.x, dy = flight.to.y - flight.from.y
            let heading = flight.craft == .rocket ? CATransform3DMakeRotation(atan2(dy, dx), 0, 0, 1)
                : flight.craft == .ringed ? CATransform3DMakeRotation(-0.24, 0, 0, 1)    // its ring tilted, like a planet's
                : CATransform3DIdentity
            rig.transform = dx < 0 ? CATransform3DConcat(heading, CATransform3DMakeScale(-1, 1, 1)) : heading
            rig.position = CGPoint(x: flight.from.x + dx * flight.still, y: flight.from.y + dy * flight.still)
            craftLayer.addSublayer(rig)
            craftRigs.append(rig)
        }
    }

    /// Lights along the skyway's side (where the Home poster lights it at night): sun orange by day, window
    /// gold at night.
    private static let dayLight = Theme.rgb(0xE8742F), nightLight = Theme.rgb(0xF4C26B)

    private func buildLights(_ f: DesertFrame) {
        skywayLights.forEach { $0.removeFromSuperlayer() }
        let side = DesertScene.skywaySide.reversed()             // left to right
        skywayLights = stride(from: Self.sceneFromX + 24, through: 1488, by: 36).compactMap { x -> CALayer? in
            guard let i = side.firstIndex(where: { $0.0 >= x }), i > side.startIndex else { return nil }
            let a = side[side.index(before: i)], b = side[i]
            let y = a.1 + (b.1 - a.1) * (x - a.0) / (b.0 - a.0) + 4
            let dot = CALayer()
            let r: CGFloat = 2
            dot.bounds = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
            dot.cornerRadius = r
            dot.backgroundColor = (builtFor?.dark == true ? Self.nightLight : Self.dayLight).cgColor
            dot.position = CGPoint(x: x * f.scale + f.tx, y: y * f.scale + f.ty)
            dot.opacity = 0.9
            poster.layer.insertSublayer(dot, above: front.night)
            return dot
        }
    }

    private func buildTwinkles(size: CGSize) {
        twinkles.forEach { $0.removeFromSuperlayer() }
        twinkles = DesigningArt.twinkles.map { t in
            let star = CALayer()
            star.bounds = CGRect(x: 0, y: 0, width: 2.6, height: 2.6)
            star.cornerRadius = 1.3
            star.backgroundColor = UIColor(DesertPalette.night.star).cgColor
            star.position = CGPoint(x: t.x * size.width, y: t.y * size.height)
            sky.night.addSublayer(star)                           // only out at night, with the night sky
            return star
        }
    }

    // MARK: Motion

    /// A keyframe animation on the day/night cycle, started where the card's first look is.
    private func cycled(_ keyPath: String, _ values: [Any], _ times: [Double], startAtNight: Bool) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.keyTimes = times.map { NSNumber(value: $0) }
        a.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: max(0, times.count - 1))
        a.duration = Self.cycle
        a.timeOffset = startAtNight ? Self.cycle * Self.nightStart : 0
        a.repeatCount = .infinity
        return a
    }

    private func animate(f: DesertFrame, startAtNight: Bool) {
        guard !stopped, !UIAccessibility.isReduceMotionEnabled else { return }
        let now = CACurrentMediaTime()

        // Day to night and back: the night copies fade in and out, the day title the other way round.
        for l in nightLayers {
            l.add(cycled("opacity", Cycle.night.values, Cycle.night.times, startAtNight: startAtNight), forKey: "night")
        }
        for l in [titleNight.layer, promptNight.layer] {
            l.add(cycled("opacity", Cycle.ink.values, Cycle.ink.times, startAtNight: startAtNight), forKey: "night")
        }
        for l in [titleDay.layer, promptDay.layer] {
            l.add(cycled("opacity", Cycle.ink.values.map { 1 - $0 }, Cycle.ink.times, startAtNight: startAtNight), forKey: "night")
        }
        dusk.add(cycled("opacity", Cycle.dusk.values, Cycle.dusk.times, startAtNight: startAtNight), forKey: "dusk")
        let dotColors = Cycle.ink.values.map { UIColor($0 > 0.5 ? DesertPalette.night.underline : DesertPalette.day.underline).cgColor }
        for dot in titleDots { dot.add(cycled("backgroundColor", dotColors, Cycle.ink.times, startAtNight: startAtNight), forKey: "night") }
        let down = Self.setDrop * f.scale
        sun.add(cycled("transform.translation.y", Cycle.sun.values.map { $0 * down }, Cycle.sun.times, startAtNight: startAtNight), forKey: "set")
        moon.add(cycled("transform.translation.y", Cycle.moon.values.map { $0 * down }, Cycle.moon.times, startAtNight: startAtNight), forKey: "set")
        let rule = Cycle.ink.values.map { UIColor($0 > 0.5 ? DesertPalette.night.underline : DesertPalette.day.underline).cgColor }
        underline.layer.add(cycled("backgroundColor", rule, Cycle.ink.times, startAtNight: startAtNight), forKey: "night")

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 150                                         // a slow turn: about 2.4° a second
        spin.repeatCount = .infinity
        galaxySpin.add(spin, forKey: "spin")

        for (rig, flight) in zip(craftRigs, flights) {
            let path = CGMutablePath()
            path.move(to: flight.from)
            path.addLine(to: flight.to)
            let fly = CAKeyframeAnimation(keyPath: "position")
            fly.path = path
            fly.duration = flight.duration
            fly.timeOffset = flight.duration * flight.head
            fly.repeatCount = .infinity
            rig.add(fly, forKey: "fly")
            guard let body = rig.sublayers?.first(where: { $0.name == "body" }) else { continue }
            if flight.bob > 0 {
                let bob = CABasicAnimation(keyPath: "transform.translation.y")
                bob.fromValue = -flight.bob
                bob.toValue = flight.bob
                bob.duration = flight.bobPeriod / 2
                bob.autoreverses = true
                bob.repeatCount = .infinity
                bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                body.add(bob, forKey: "bob")
            }
            if flight.craft == .saucer {
                let wobble = CABasicAnimation(keyPath: "transform.rotation.z")
                wobble.fromValue = -0.06
                wobble.toValue = 0.06
                wobble.duration = 1.7
                wobble.autoreverses = true
                wobble.repeatCount = .infinity
                wobble.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                body.add(wobble, forKey: "wobble")
            }
            if let flame = body.sublayers?.first(where: { $0.name == "flame" }) {
                let flicker = CABasicAnimation(keyPath: "transform.scale.x")
                flicker.fromValue = 0.7
                flicker.toValue = 1.15
                flicker.duration = 0.11
                flicker.autoreverses = true
                flicker.repeatCount = .infinity
                flame.add(flicker, forKey: "flicker")
            }
        }

        // The skyway's lights run toward the city, over and over (the work is going on), in the cycle's colors.
        let lightColors = Cycle.night.values.map { ($0 > 0.5 ? Self.nightLight : Self.dayLight).cgColor }
        for (i, light) in skywayLights.enumerated() {
            light.opacity = 0.28
            let run = CAKeyframeAnimation(keyPath: "opacity")
            run.values = [0.28, 1, 0.28, 0.28]
            run.keyTimes = [0, 0.08, 0.34, 1]
            run.duration = 3.2
            run.beginTime = now + Double(i) * 0.16
            run.repeatCount = .infinity
            light.add(run, forKey: "run")
            light.add(cycled("backgroundColor", lightColors, Cycle.night.times, startAtNight: startAtNight), forKey: "night")
        }

        for (i, star) in twinkles.enumerated() {
            let twinkle = CABasicAnimation(keyPath: "opacity")
            twinkle.fromValue = 0.15
            twinkle.toValue = 1
            twinkle.duration = 1.3 + Double(i % 3) * 0.45
            twinkle.autoreverses = true
            twinkle.repeatCount = .infinity
            twinkle.timeOffset = Double(i) * 0.7
            star.add(twinkle, forKey: "twinkle")
        }
    }

    /// The three dots after the title pulse in turn, like a held breath, while it works. Only their brightness
    /// changes, so they keep going under Reduce Motion too.
    private func startDots() {
        titleDots = (0..<3).map { i in
            let dot = CALayer()
            dot.backgroundColor = UIColor(DesertPalette.day.underline).cgColor
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.25, 1, 0.25, 0.25]
            pulse.keyTimes = [0, 0.2, 0.5, 1]
            pulse.duration = 1.35
            pulse.beginTime = CACurrentMediaTime() + Double(i) * 0.2
            pulse.repeatCount = .infinity
            dot.opacity = 0.25
            dot.add(pulse, forKey: "pulse")
            poster.layer.addSublayer(dot)
            return dot
        }
    }

    /// Just after the end of the title's words, sitting on its baseline.
    private func placeTitleDots() {
        guard let font = titleDay.font else { return }
        let words = titleDay.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: titleDay.bounds.height)).width
        let d = max(4.5, font.pointSize * 0.19)
        let baseline = titleDay.frame.minY + (titleDay.bounds.height - font.lineHeight) / 2 + font.ascender
        for (i, dot) in titleDots.enumerated() {
            dot.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            dot.cornerRadius = d / 2
            dot.position = CGPoint(x: titleDay.frame.minX + min(words, titleDay.bounds.width - 4 * d) + d * (0.95 + 1.6 * CGFloat(i)),
                                   y: baseline - d / 2)
        }
    }

    private func showTitle(_ text: String) {
        titleDay.text = text
        titleNight.text = text
        placeTitleDots()
    }

    /// Change the animated status line, e.g. to "Fixing a problem" while a broken first attempt is regenerated.
    func setStatus(_ text: String) {
        baseTitle = text
        showTitle(text)
    }

    /// Stop all animation (call before removing).
    func stop() {
        stopped = true
        func still(_ l: CALayer) { l.removeAllAnimations(); l.sublayers?.forEach(still) }
        still(poster.layer)
    }
}
