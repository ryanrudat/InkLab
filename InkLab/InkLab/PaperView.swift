import UIKit

/// Draws the page background (ruled / grid / dotted / blank) behind the ink.
final class PaperView: UIView {
    var paper: PaperType = .ruled { didSet { setNeedsDisplay() } }
    /// Vertical scroll offset of the canvas — the ruling tiles by this so it scrolls with the page.
    var contentOffsetY: CGFloat = 0 { didSet { if oldValue != contentOffsetY { setNeedsDisplay() } } }
    private let spacing: CGFloat = 28

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        Theme.paper.setFill()
        ctx.fill(rect)

        let line = Theme.rule
        ctx.setLineWidth(0.5)
        line.setStroke()

        // Phase the horizontal ruling by the scroll offset so lines move with the content.
        let phase = contentOffsetY.truncatingRemainder(dividingBy: spacing)
        let firstY = spacing - phase   // first horizontal line at or below the top edge

        switch paper {
        case .blank:
            break
        case .ruled:
            var y = firstY
            while y < rect.height {
                if y >= 0 { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: rect.width, y: y)) }
                y += spacing
            }
            ctx.strokePath()
        case .grid:
            var x: CGFloat = 0
            while x < rect.width { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: rect.height)); x += spacing }
            var y = firstY
            while y < rect.height {
                if y >= 0 { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: rect.width, y: y)) }
                y += spacing
            }
            ctx.strokePath()
        case .dotted:
            line.setFill()
            var y = firstY
            while y < rect.height {
                if y >= 0 {
                    var x = spacing
                    while x < rect.width { ctx.fillEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)); x += spacing }
                }
                y += spacing
            }
        }
    }
}
