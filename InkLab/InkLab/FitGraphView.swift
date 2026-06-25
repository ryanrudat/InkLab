import UIKit

/// A native, deterministic graph that draws a best-fit curve over the user's sketched points, with the
/// model type, equation, and R² (from `InkLabFit` — correct by construction, never model-generated).
/// State is a `FitGraphState` JSON in the object's `.widget` payload (kind `native:fitGraph`).
final class FitGraphView: UIView, NativeWidgetView {
    var widgetKind: String { "fitGraph" }
    var initialState: String { "{}" }
    var onStateCommit: ((_ old: String, _ new: String) -> Void)?   // read-only graph: never fires

    private var state: FitGraphState?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        isOpaque = true
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func loadState(_ json: String) {
        state = try? JSONDecoder().decode(FitGraphState.self, from: Data(json.utf8))
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let s = state, !(s.points.isEmpty && s.curve.isEmpty) else { return }
        let labelH: CGFloat = 34, margin: CGFloat = 10
        let plot = CGRect(x: margin, y: labelH, width: bounds.width - 2 * margin, height: bounds.height - labelH - margin)
        guard plot.width > 4, plot.height > 4 else { return }

        let all = s.points + s.curve
        let xsv = all.map { $0[0] }, ysv = all.map { $0[1] }
        guard let minX = xsv.min(), let maxX = xsv.max(), let minY = ysv.min(), let maxY = ysv.max() else { return }
        let spanX = max(maxX - minX, 1e-9), spanY = max(maxY - minY, 1e-9)
        func map(_ p: [Double]) -> CGPoint {
            CGPoint(x: plot.minX + CGFloat((p[0] - minX) / spanX) * plot.width,
                    y: plot.maxY - CGFloat((p[1] - minY) / spanY) * plot.height)   // y up
        }

        // Plot frame.
        UIColor.separator.setStroke()
        let border = UIBezierPath(rect: plot); border.lineWidth = 0.5; border.stroke()

        // The user's sampled points.
        UIColor.systemGray2.setFill()
        for p in s.points { let c = map(p); UIBezierPath(ovalIn: CGRect(x: c.x - 1.8, y: c.y - 1.8, width: 3.6, height: 3.6)).fill() }

        // The fitted curve.
        if s.curve.count > 1 {
            let path = UIBezierPath(); path.lineWidth = 2; path.lineJoinStyle = .round
            path.move(to: map(s.curve[0]))
            for p in s.curve.dropFirst() { path.addLine(to: map(p)) }
            UIColor.systemBlue.setStroke(); path.stroke()
        }

        // Header: model · R², then the equation.
        text("\(s.model)  ·  R² = \(String(format: "%.3f", s.rSquared))",
             in: CGRect(x: margin, y: 3, width: plot.width, height: 14),
             font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabel)
        text(s.equation, in: CGRect(x: margin, y: 16, width: plot.width, height: 17),
             font: .systemFont(ofSize: 13, weight: .medium), color: .label)
    }

    private func text(_ s: String, in rect: CGRect, font: UIFont, color: UIColor) {
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        (s as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
    }
}
