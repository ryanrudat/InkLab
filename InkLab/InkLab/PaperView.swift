import UIKit

/// Draws the page background (ruled / grid / dotted / blank) behind the ink.
final class PaperView: UIView {
    var paper: PaperType = .ruled { didSet { setNeedsDisplay() } }
    private let spacing: CGFloat = 28

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        UIColor.systemBackground.setFill()
        ctx.fill(rect)

        let line = UIColor.separator.withAlphaComponent(0.6)
        ctx.setLineWidth(0.5)
        line.setStroke()

        switch paper {
        case .blank:
            break
        case .ruled:
            var y = spacing
            while y < rect.height {
                ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: rect.width, y: y)); y += spacing
            }
            ctx.strokePath()
        case .grid:
            var x: CGFloat = 0
            while x < rect.width { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: rect.height)); x += spacing }
            var y: CGFloat = 0
            while y < rect.height { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: rect.width, y: y)); y += spacing }
            ctx.strokePath()
        case .dotted:
            line.setFill()
            var y = spacing
            while y < rect.height {
                var x = spacing
                while x < rect.width { ctx.fillEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)); x += spacing }
                y += spacing
            }
        }
    }
}
