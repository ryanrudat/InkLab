import SwiftUI
import UIKit

/// InkLab's visual language: Apple-style restraint with a 1950s/60s retro-futurist desert poster (a striped
/// sun over a mesa, a silver city on a saucer platform, a skyway). Structure, spacing and controls stay native
/// and quiet; the era shows in a few deliberate places only:
///   • color with meaning: cream paper and charcoal ink; sun orange for tools, the tutor and primary actions;
///     rust for the red pen (mistakes); sun yellow for the highlighter; sand for soft tints; slate for steel;
///   • type: Futura for titles only (the mid-century face), SF Rounded for the interface;
///   • signature details: the striped sun, thin steel rims on raised surfaces, and the Home header scene
///     (`DesertHeader`). In dark mode the same desert is at night: navy sky, a pale moon, lit windows.
/// Every color is a light/dark pair, so views stay correct in both modes.
enum Theme {
    // MARK: Colors

    /// The notebook page and the Home background.
    static let paper = dynamic(0xFCF6EE, 0x182133)
    /// Text and default ink.
    static let ink = dynamic(0x1E2530, 0xF4EAD7)
    /// Secondary text (captions, metadata).
    static let inkSecondary = dynamic(0x85867F, 0xA8B0BB)
    /// Page ruling / grid / dots.
    static let rule = dynamic(0xEBDCCB, 0x2C374C)
    /// Raised surfaces: cards, the dock, sheets.
    static let card = dynamic(0xFFFBF6, 0x212B3F)
    /// Card header / footer bars.
    static let cardBar = dynamic(0xF7ECDF, 0x28334A)
    /// Thin steel rims on raised surfaces.
    static let chrome = dynamic(0xDCD2C6, 0x3A465C)
    /// Primary accent (the sun): tools, the tutor, primary actions.
    static let sun = dynamic(0xE8742F, 0xED9B50)
    /// Text on a sun fill.
    static let onSun = dynamic(0xFFFFFF, 0x2A1608)
    /// The red pen: mistakes, destructive actions.
    static let rust = dynamic(0xC2452A, 0xFF7B5E)
    /// Highlighter, sticky notes.
    static let sunYellow = dynamic(0xF6C35B, 0xE8B550)
    /// Soft tint (tutor, engine results).
    static let sand = dynamic(0xF9E3CC, 0x3A2F35)
    /// Text on sand.
    static let onSand = dynamic(0x8A3E1C, 0xF6C9A4)
    /// Steel: secondary controls, rims, quiet icons.
    static let slate = dynamic(0x5F6B7A, 0x9AA6B6)
    /// Sage: "this step checks out".
    static let sage = dynamic(0x4E8A5E, 0x8FC79E)
    /// A cool steel tint: engine-result callouts (exact computation).
    static let steelTint = dynamic(0xE8ECF0, 0x263044)
    /// Pip's voice (the tutor's words): atomic-age turquoise, so what Pip says never reads like your own
    /// writing or the orange chrome around it.
    static let pip = dynamic(0x1F6E75, 0x7ED3CE)
    /// A warm sand tint: the tutor's note.
    static let sandTint = dynamic(0xFDF1E4, 0x2B2B39)

    /// Cover colors for new notebooks and the recolor sheet (stored as hex; mode-stable on purpose:
    /// a cover is an object with its own color, like paper stock). Poster inks: sun, rust, mustard,
    /// steel blue, slate, saddle, sage, dusty rose.
    static let coverPalette = ["#E8742F", "#C2452A", "#E2A93B", "#5F7A8F", "#3E4A5C", "#8C5A3C", "#7E9B86", "#B66A7E"]

    // MARK: Type

    /// Futura for titles (notebook names, widget headers, "InkLab"). Falls back to the rounded system font.
    static func title(_ size: CGFloat, bold: Bool = false) -> UIFont {
        UIFont(name: bold ? "Futura-Bold" : "Futura-Medium", size: size) ?? ui(size, .semibold)
    }

    /// SF Rounded for the interface.
    static func ui(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: rounded, size: size)
    }

    // MARK: Shape

    static let cardRadius: CGFloat = 16
    static let controlRadius: CGFloat = 12
    static let chromeWidth: CGFloat = 1

    /// The AI / tutor mark (SF Symbol "sparkle", a four-point star).
    static let starSymbol = "sparkle"
    static let star = "✦"

    // MARK: UIKit helpers

    /// Card styling: card surface, steel rim, continuous corners.
    static func styleCard(_ layer: CALayer, radius: CGFloat = cardRadius) {
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.borderWidth = chromeWidth
        layer.borderColor = chrome.cgColor
    }

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) }
    }

    static func rgb(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// The poster's striped sun as a small mark: an orange disc whose lower part is cut by widening bands of
/// the surface color behind it (proportions taken from the Home header's sun).
final class StripedSunView: UIView {
    /// The surface the sun sits on; the bands are painted in it.
    var bandColor: UIColor = Theme.card { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: StripedSunView, _) in view.setNeedsDisplay() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let r = min(bounds.width, bounds.height) / 2
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let cut = c.y + r * 0.835
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.clip()
        ctx.clip(to: CGRect(x: 0, y: 0, width: bounds.width, height: cut))
        let colors = [Theme.rgb(0xF98830).cgColor, Theme.rgb(0xFDA250).cgColor, Theme.rgb(0xFCC477).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.6, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: c.y - r), end: CGPoint(x: 0, y: cut), options: [])
        }
        ctx.restoreGState()
        bandColor.setFill()
        for (y, h) in [(0.157, 0.031), (0.323, 0.031), (0.465, 0.039), (0.606, 0.047), (0.74, 0.055)] as [(CGFloat, CGFloat)] {
            ctx.fill(CGRect(x: c.x - r - 1, y: c.y + y * r, width: 2 * r + 2, height: max(1, h * r)))
        }
    }
}

// MARK: SwiftUI

extension Color {
    /// A fixed sRGB color from 0xRRGGBB.
    init(rgb v: UInt32) {
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    static let inkPaper = Color(uiColor: Theme.paper)
    static let inkInk = Color(uiColor: Theme.ink)
    static let inkInkSecondary = Color(uiColor: Theme.inkSecondary)
    static let inkCard = Color(uiColor: Theme.card)
    static let inkChrome = Color(uiColor: Theme.chrome)
    static let inkSun = Color(uiColor: Theme.sun)
    static let inkRust = Color(uiColor: Theme.rust)
    static let inkSunYellow = Color(uiColor: Theme.sunYellow)
    static let inkSand = Color(uiColor: Theme.sand)
    static let inkSlate = Color(uiColor: Theme.slate)
}

extension Font {
    /// Futura title (SwiftUI).
    static func inkTitle(_ size: CGFloat, bold: Bool = false) -> Font { .custom(bold ? "Futura-Bold" : "Futura-Medium", size: size) }
    /// SF Rounded interface text (SwiftUI).
    static func inkUI(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .rounded) }
}

/// A raised card in SwiftUI: card surface, steel rim, continuous corners.
struct InkCardBackground: ViewModifier {
    var radius: CGFloat = Theme.cardRadius
    func body(content: Content) -> some View {
        content
            .background(Color.inkCard, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.inkChrome, lineWidth: Theme.chromeWidth))
    }
}

extension View {
    func inkCard(radius: CGFloat = Theme.cardRadius) -> some View { modifier(InkCardBackground(radius: radius)) }
}
