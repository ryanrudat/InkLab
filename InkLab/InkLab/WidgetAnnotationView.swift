import UIKit

/// A transparent ink layer that sits ON TOP of a generated widget (e.g. a graph) so you can write on
/// it. The model is the same as the rest of the app: **Pencil draws, finger operates the widget**.
/// When `isAnnotating` is on (the ✏️ toggle), finger draws too — so it's usable in the Simulator,
/// which has no Pencil. Strokes are simple polylines (annotation, not precise ink); they render in a
/// visible colour but rasterize black-on-white for recognition.
///
/// Erasing mirrors the page: the per-widget 🧽 toggle (`isErasing`) lets a finger (or Pencil) rub out
/// whole strokes, and a Pencil also erases whenever the app's global Eraser tool is selected
/// (`pencilErases`) — so the Pencil does to a widget's ink exactly what it does to the page, and the
/// Eraser tool can no longer accidentally *draw* red ink on a widget.
final class WidgetAnnotationView: UIView {
    /// Toggle: capture finger touches and DRAW with them. Off → only a Pencil draws; finger falls through.
    var isAnnotating = false
    /// Toggle: capture finger touches and ERASE the stroke under them (the per-widget 🧽 button).
    var isErasing = false
    /// The app's global Eraser tool is active, so a Pencil erases this widget's ink instead of drawing.
    var pencilErases = false
    /// Fired whenever the stroke set changes (so the host can persist it).
    var onChanged: (() -> Void)?

    private(set) var strokes: [[CGPoint]] = []
    private var active: [CGPoint] = []
    private var activeErases = false                 // the in-flight touch is an erase, not a draw
    private let displayColor = Theme.rust
    private let lineWidth: CGFloat = 2.5
    private let eraseRadius: CGFloat = 16             // a touch within this of a stroke rubs the whole stroke out

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var hasStrokes: Bool { !strokes.isEmpty }

    func clear() { strokes = []; active = []; setNeedsDisplay(); onChanged?() }

    /// Should the touch `t` erase (vs draw)? The 🧽 toggle erases with any input; the global Eraser tool
    /// erases with the Pencil.
    private func erases(_ t: UITouch) -> Bool { isErasing || (t.type == .pencil && pencilErases) }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard bounds.contains(point) else { return nil }
        if isAnnotating || isErasing { return self }                          // a finger mode is active → capture
        if event?.allTouches?.contains(where: { $0.type == .pencil }) == true { return self }  // Pencil always: draw OR erase
        return nil                                                            // otherwise finger → operate the widget below
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        activeErases = erases(t)
        if activeErases { active = []; eraseStroke(at: p) } else { active = [p] }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        if activeErases { eraseStroke(at: p) } else { active.append(p); setNeedsDisplay() }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !activeErases, active.count > 1 { strokes.append(active) }
        active = []; activeErases = false; setNeedsDisplay(); onChanged?()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // An erase mutates `strokes` live (touchesBegan/Moved), so a CANCELLED erase — a two-finger scroll
        // claiming the touch mid-rub, or the app backgrounding — must still persist, or the rubbed-out ink
        // resurrects from the stale on-disk blob on reload. A cancelled DRAW only discards `active` (never
        // touched `strokes`), so it stays a no-op for persistence.
        let wasErasing = activeErases
        active = []; activeErases = false; setNeedsDisplay()
        if wasErasing { onChanged?() }
    }

    /// Remove every stroke passing within `eraseRadius` of `p` (whole-stroke erase — the right grain for
    /// these coarse polyline annotations, and forgiving to rub out).
    private func eraseStroke(at p: CGPoint) {
        let before = strokes.count
        strokes.removeAll { Self.distance(from: p, toPolyline: $0) <= eraseRadius }
        if strokes.count != before { setNeedsDisplay() }
    }

    /// Shortest distance from a point to a polyline (checks each segment, not just vertices, so a fast
    /// sparse stroke still erases reliably).
    private static func distance(from p: CGPoint, toPolyline pts: [CGPoint]) -> CGFloat {
        guard let first = pts.first else { return .greatestFiniteMagnitude }
        guard pts.count > 1 else { return hypot(p.x - first.x, p.y - first.y) }
        var best = CGFloat.greatestFiniteMagnitude
        for i in 1..<pts.count { best = min(best, distance(from: p, toSegment: pts[i - 1], pts[i])) }
        return best
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    override func draw(_ rect: CGRect) {
        displayColor.setStroke()
        for s in strokes { path(for: s).stroke() }
        path(for: active).stroke()
    }

    private func path(for pts: [CGPoint]) -> UIBezierPath {
        let p = UIBezierPath()
        p.lineWidth = lineWidth; p.lineCapStyle = .round; p.lineJoinStyle = .round
        guard let first = pts.first else { return p }
        p.move(to: first)
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        return p
    }

    /// Black-on-white render of the strokes for OCR (Vision/Claude need contrast, not a clear bg).
    func rasterizedImage() -> UIImage? {
        guard hasStrokes, bounds.width > 1, bounds.height > 1 else { return nil }
        return UIGraphicsImageRenderer(bounds: bounds).image { ctx in
            UIColor.white.setFill(); ctx.fill(bounds)
            UIColor.black.setStroke()
            for s in strokes { path(for: s).stroke() }
        }
    }

    // MARK: Persistence (strokes as [[ [x,y] ]] JSON — small, opaque Data the host stores per object)
    var encoded: Data? {
        try? JSONEncoder().encode(strokes.map { $0.map { [Double($0.x), Double($0.y)] } })
    }
    func load(_ data: Data) {
        guard let arr = try? JSONDecoder().decode([[[Double]]].self, from: data) else { return }
        strokes = arr.map { $0.compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil } }
        setNeedsDisplay()
    }
}
