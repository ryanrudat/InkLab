import Foundation
import InkLabRecognition   // Point, Rect

// MARK: - Draw-and-hold shape recognition (brief: hold the pencil after a stroke → it snaps to a clean form)
//
// Pure, deterministic geometry: given a hand-drawn stroke's points, decide whether it's "obviously" a
// line / arrow / ellipse / polygon and, if so, return the idealized form. The iOS layer turns the result
// back into a clean PKStroke (same ink/colour/width) and swaps it in as one undoable step. Coordinates
// are in the SAME space as the input points (canvas/content coords). Correct-or-silent: when the stroke
// isn't clearly one of these, recognition returns nil and the freehand ink is left exactly as drawn.

/// The clean form a stroke can snap to. `ellipse` with rx==ry is a circle; `polygon` covers
/// triangles/rectangles/quads (straight edges between crisp vertices, closed).
public enum RecognizedShape: Equatable, Sendable {
    case line(from: Point, to: Point)
    case arrow(from: Point, to: Point)              // straight shaft, arrowhead at `to`
    case ellipse(center: Point, rx: Double, ry: Double)
    case polygon(vertices: [Point], closed: Bool)
}

/// Which shapes the user has enabled (mirrors the Settings toggles).
public struct ShapeOptions: Sendable, Equatable {
    public var lines: Bool
    public var arrows: Bool
    public var ellipses: Bool
    public var polygons: Bool
    public init(lines: Bool = true, arrows: Bool = true, ellipses: Bool = true, polygons: Bool = true) {
        self.lines = lines; self.arrows = arrows; self.ellipses = ellipses; self.polygons = polygons
    }
    public static let all = ShapeOptions()
    public var any: Bool { lines || arrows || ellipses || polygons }
}

/// Recognize a hand-drawn stroke as a clean shape, or nil if it isn't clearly one (leave it as ink).
/// `raw` is the stroke's sampled points in canvas coords.
public func recognizeShape(_ raw: [Point], options: ShapeOptions = .all) -> RecognizedShape? {
    guard options.any else { return nil }
    let pts = resample(dedupe(raw), count: 64)
    guard pts.count >= 4, let bbox = boundingRect(pts) else { return nil }
    let diag = (bbox.width * bbox.width + bbox.height * bbox.height).squareRoot()
    guard diag >= 16 else { return nil }                 // too small to be an intentional shape

    let start = pts.first!, end = pts.last!
    let pathLen = polylineLength(pts)
    guard pathLen > 1 else { return nil }
    let endGap = dist(start, end)
    let closed = endGap < 0.20 * pathLen || endGap < 0.18 * diag

    // 1) OPEN stroke → arrow (straight shaft + barb) or straight line.
    if !closed {
        // Arrow FIRST: a small barb can still leave the stroke looking "straight" start→end, so the plain
        // line test would otherwise swallow it. arrowTip returns nil for a plain line (tip == last point).
        if options.arrows, let tip = arrowTip(pts) {
            let (a, b) = snapToAxis(start, tip); return .arrow(from: a, to: b)
        }
        let chord = dist(start, end)
        if options.lines, chord > 0.001, maxPerpDeviation(pts, a: start, b: end) / chord < 0.10 {
            let (a, b) = snapToAxis(start, end); return .line(from: a, to: b)
        }
        // Arrow-shaped but arrows are disabled → still straighten the shaft as a plain line.
        if options.lines, let tip = arrowTip(pts) {
            let (a, b) = snapToAxis(start, tip); return .line(from: a, to: b)
        }
        return nil
    }

    // 2) CLOSED stroke → ellipse (round) or polygon (cornered).
    if options.ellipses, let e = fitEllipse(pts, bbox: bbox) { return e }
    if options.polygons {
        let corners = dominantCorners(pts, diag: diag)
        switch corners.count {
        case 3:
            return .polygon(vertices: corners, closed: true)
        case 4:
            // A "boxy" quad (edges alternate near-horizontal / near-vertical) snaps to the clean,
            // right-angled axis-aligned bounding box; an arbitrary quad keeps its detected corners.
            return .polygon(vertices: isRectangular(corners) ? rectCorners(bbox) : corners, closed: true)
        case 5...8:
            return .polygon(vertices: corners, closed: true)
        default:
            return nil   // too many/few corners and not round → leave as freehand
        }
    }
    return nil
}

// MARK: - Geometry helpers

private func dist(_ a: Point, _ b: Point) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }

private func polylineLength(_ pts: [Point]) -> Double {
    guard pts.count > 1 else { return 0 }
    var len = 0.0
    for i in 1..<pts.count { len += dist(pts[i - 1], pts[i]) }
    return len
}

/// Drop consecutive duplicate / near-duplicate points (a held pencil emits many samples at one spot).
private func dedupe(_ pts: [Point]) -> [Point] {
    var out: [Point] = []
    for p in pts where out.last.map({ dist($0, p) > 0.01 }) ?? true { out.append(p) }
    return out
}

/// Resample a polyline to `count` points evenly spaced by arc length (stabilizes corner detection).
private func resample(_ pts: [Point], count: Int) -> [Point] {
    guard pts.count > 1, count > 1 else { return pts }
    let total = polylineLength(pts)
    guard total > 0 else { return pts }
    let step = total / Double(count - 1)
    var out: [Point] = [pts[0]]
    var prev = pts[0], acc = 0.0, i = 1
    while i < pts.count {
        let cur = pts[i]
        let d = dist(prev, cur)
        if acc + d >= step, d > 0 {
            let t = (step - acc) / d
            let np = Point(x: prev.x + t * (cur.x - prev.x), y: prev.y + t * (cur.y - prev.y))
            out.append(np)
            prev = np
            acc = 0
        } else {
            acc += d
            prev = cur
            i += 1
        }
    }
    if out.count < count, let last = pts.last { out.append(last) }
    return out
}

/// Max perpendicular distance of any point from the infinite line through a→b.
private func maxPerpDeviation(_ pts: [Point], a: Point, b: Point) -> Double {
    let dx = b.x - a.x, dy = b.y - a.y
    let len = (dx * dx + dy * dy).squareRoot()
    guard len > 0 else { return pts.map { dist($0, a) }.max() ?? 0 }
    var maxd = 0.0
    for p in pts {
        let d = abs((p.x - a.x) * dy - (p.y - a.y) * dx) / len
        if d > maxd { maxd = d }
    }
    return maxd
}

/// Snap a nearly-horizontal/vertical segment to exactly horizontal/vertical (within ~7°), like Notes.
private func snapToAxis(_ a: Point, _ b: Point) -> (Point, Point) {
    let dx = b.x - a.x, dy = b.y - a.y
    let len = (dx * dx + dy * dy).squareRoot()
    guard len > 0 else { return (a, b) }
    let tol = 0.12                                   // sin(~7°)
    if abs(dy) / len < tol { let y = (a.y + b.y) / 2; return (Point(x: a.x, y: y), Point(x: b.x, y: y)) }
    if abs(dx) / len < tol { let x = (a.x + b.x) / 2; return (Point(x: x, y: a.y), Point(x: x, y: b.y)) }
    return (a, b)
}

/// If the stroke is a straight shaft plus a short barb that bends back at the far end, return the tip
/// (end of the shaft = where the arrow points). Otherwise nil.
private func arrowTip(_ pts: [Point]) -> Point? {
    guard pts.count >= 6 else { return nil }
    let start = pts[0]
    // Tip = point farthest from the start (an arrowhead curls back, so the shaft end is the extreme).
    var ti = 0, best = 0.0
    for (i, p) in pts.enumerated() { let d = dist(start, p); if d > best { best = d; ti = i } }
    guard ti >= 2, ti <= pts.count - 2 else { return nil }   // need a shaft AND a tail
    let tip = pts[ti]
    let shaft = Array(pts[0...ti]), tail = Array(pts[ti...])
    let shaftLen = dist(start, tip)
    guard shaftLen > 1 else { return nil }
    // Shaft must be straight, and the tail (barb) short relative to the shaft.
    guard maxPerpDeviation(shaft, a: start, b: tip) / shaftLen < 0.14 else { return nil }
    let tailLen = polylineLength(tail)
    guard tailLen > 0.08 * shaftLen, tailLen < 0.5 * shaftLen else { return nil }
    return tip
}

/// Fit an axis-aligned ellipse to a closed loop; nil if the points don't hug it (so a polygon isn't
/// mistaken for an ellipse). Collapses to a circle when the two radii are close.
private func fitEllipse(_ pts: [Point], bbox: Rect) -> RecognizedShape? {
    let cx = bbox.x + bbox.width / 2, cy = bbox.y + bbox.height / 2
    var rx = bbox.width / 2, ry = bbox.height / 2
    guard rx > 1, ry > 1 else { return nil }
    let ratio = min(rx, ry) / max(rx, ry)
    guard ratio > 0.35 else { return nil }            // extreme aspect ⇒ likely a line/sliver, not an ellipse
    // Each point should satisfy ((x-cx)/rx)^2 + ((y-cy)/ry)^2 ≈ 1.
    var err = 0.0
    for p in pts {
        let nx = (p.x - cx) / rx, ny = (p.y - cy) / ry
        err += abs(nx * nx + ny * ny - 1)
    }
    let meanErr = err / Double(pts.count)
    guard meanErr < 0.20 else { return nil }          // too far from an ellipse ⇒ leave as polygon/freehand
    if ratio > 0.82 { let r = (rx + ry) / 2; rx = r; ry = r }   // near-circular ⇒ snap to a true circle
    return .ellipse(center: Point(x: cx, y: cy), rx: rx, ry: ry)
}

/// Dominant corners of a closed stroke via Ramer–Douglas–Peucker, with the polygon closed up.
private func dominantCorners(_ pts: [Point], diag: Double) -> [Point] {
    let eps = 0.045 * diag
    var simplified = rdp(pts, epsilon: eps)
    // Closed shape: RDP keeps the (near-equal) first & last as separate vertices — merge them.
    if simplified.count >= 2, dist(simplified.first!, simplified.last!) < 0.10 * diag {
        simplified.removeLast()
    }
    return simplified
}

/// Ramer–Douglas–Peucker polyline simplification (keeps the most significant vertices).
private func rdp(_ pts: [Point], epsilon: Double) -> [Point] {
    guard pts.count > 2 else { return pts }
    let a = pts.first!, b = pts.last!
    var index = 0, maxd = 0.0
    for i in 1..<(pts.count - 1) {
        let d = perpDistance(pts[i], a: a, b: b)
        if d > maxd { maxd = d; index = i }
    }
    if maxd > epsilon {
        let left = rdp(Array(pts[0...index]), epsilon: epsilon)
        let right = rdp(Array(pts[index...]), epsilon: epsilon)
        return left.dropLast() + right
    }
    return [a, b]
}

private func perpDistance(_ p: Point, a: Point, b: Point) -> Double {
    let dx = b.x - a.x, dy = b.y - a.y
    let len = (dx * dx + dy * dy).squareRoot()
    guard len > 0 else { return dist(p, a) }
    return abs((p.x - a.x) * dy - (p.y - a.y) * dx) / len
}

/// A 4-corner loop is "rectangular" when its edges alternate near-horizontal / near-vertical.
private func isRectangular(_ c: [Point]) -> Bool {
    guard c.count == 4 else { return false }
    for i in 0..<4 {
        let a = c[i], b = c[(i + 1) % 4]
        let dx = abs(b.x - a.x), dy = abs(b.y - a.y)
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0 else { return false }
        let horizontal = dx / len > 0.85, vertical = dy / len > 0.85
        guard horizontal || vertical else { return false }
        // Even edges horizontal, odd edges vertical (or vice-versa) — i.e. they alternate.
        if i % 2 == 0, !horizontal, !vertical { return false }
    }
    return true
}

private func rectCorners(_ b: Rect) -> [Point] {
    [Point(x: b.x, y: b.y), Point(x: b.x + b.width, y: b.y),
     Point(x: b.x + b.width, y: b.y + b.height), Point(x: b.x, y: b.y + b.height)]
}
