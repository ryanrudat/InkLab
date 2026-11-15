import UIKit

/// While InkLab reads (the tutor, Check, Recognize), the writing it is reading lights up, not a box round
/// it: a soft sun-coloured glow settles on the strokes themselves and a bright trace runs along them in
/// the order they were written, like the pen going over them again. Desert palette and the same easy
/// sweep timing as the "Designing" card. Under Reduce Motion the glow just stays, still.
final class InkScanView: UIView {
    private let glow = CAShapeLayer()
    private let trace = CAShapeLayer()
    private var paths: [[CGPoint]] = []
    private var length: CGFloat = 0

    /// `strokes`: each stroke's points along its rendered path, in the overlay's (content) coordinates.
    init(strokes: [[CGPoint]]) {
        let points = strokes.flatMap { $0 }
        let xs = points.map(\.x), ys = points.map(\.y)
        let bounds = CGRect(x: (xs.min() ?? 0), y: (ys.min() ?? 0),
                            width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
        super.init(frame: bounds.insetBy(dx: -14, dy: -14))
        isUserInteractionEnabled = false
        accessibilityIdentifier = "inkScan"
        paths = strokes.filter { !$0.isEmpty }
        let path = CGMutablePath()
        for stroke in paths {
            path.move(to: CGPoint(x: stroke[0].x - frame.minX, y: stroke[0].y - frame.minY))
            if stroke.count == 1 { path.addLine(to: CGPoint(x: stroke[0].x - frame.minX + 0.5, y: stroke[0].y - frame.minY)) }
            for (a, b) in zip(stroke, stroke.dropFirst()) {
                path.addLine(to: CGPoint(x: b.x - frame.minX, y: b.y - frame.minY))
                length += hypot(b.x - a.x, b.y - a.y)
            }
        }
        for l in [glow, trace] {
            l.path = path
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
            layer.addSublayer(l)
        }
        glow.lineWidth = 11
        trace.lineWidth = 3.5
        trace.shadowRadius = 5
        trace.shadowOpacity = 0.9
        trace.shadowOffset = .zero
        trace.strokeEnd = 0
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: InkScanView, _: UITraitCollection) in self.applyColors() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyColors() {
        traitCollection.performAsCurrent {
            glow.strokeColor = Theme.sun.withAlphaComponent(0.16).cgColor
            trace.strokeColor = Theme.sun.cgColor
            trace.shadowColor = Theme.sunYellow.cgColor
        }
    }

    /// Fade the glow in, then run the trace along the writing until `finish()`.
    func start() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.25
        glow.add(fade, forKey: "in")
        guard !UIAccessibility.isReduceMotionEnabled, length > 0 else { trace.isHidden = true; return }
        // A comet about 140pt long (shorter on short writing) at a steady writing-like pace.
        let tail = min(0.35, 140 / max(length, 1))
        let duration = min(2.6, max(1.1, Double(length) / 650)) * (1 + Double(tail))
        let end = CAKeyframeAnimation(keyPath: "strokeEnd")
        end.values = [0, 1, 1]
        end.keyTimes = [0, NSNumber(value: 1 / (1 + Double(tail))), 1]
        let start = CAKeyframeAnimation(keyPath: "strokeStart")
        start.values = [0, 0, 1]
        start.keyTimes = [0, NSNumber(value: Double(tail) / (1 + Double(tail))), 1]
        let group = CAAnimationGroup()
        group.animations = [end, start]
        group.duration = duration
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        trace.strokeEnd = 1
        trace.add(group, forKey: "trace")
    }

    /// The reading finished: let the light go out, then leave.
    func finish() {
        UIView.animate(withDuration: 0.25, animations: { self.alpha = 0 }, completion: { _ in self.removeFromSuperview() })
    }
}
