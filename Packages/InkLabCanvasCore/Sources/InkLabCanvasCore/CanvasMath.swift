import Foundation
import InkLabRecognition   // Point, Rect
import InkLabDoc           // Transform

// MARK: - Rotated rectangles (objects carry a Transform{x,y,width,height,rotation})

/// The four corners of an object's box, rotated by `rotation` about its centre, in canvas coords.
public func corners(of t: Transform) -> [Point] {
    let cx = t.x + t.width / 2, cy = t.y + t.height / 2
    let hw = t.width / 2, hh = t.height / 2
    let c = cos(t.rotation), s = sin(t.rotation)
    return [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)].map { lx, ly in
        Point(x: cx + lx * c - ly * s, y: cy + lx * s + ly * c)
    }
}

/// Is a point inside an object's (possibly rotated) box?
public func pointInRotatedRect(_ p: Point, _ t: Transform) -> Bool {
    let cx = t.x + t.width / 2, cy = t.y + t.height / 2
    let c = cos(-t.rotation), s = sin(-t.rotation)         // rotate point into the box's local frame
    let dx = p.x - cx, dy = p.y - cy
    let lx = dx * c - dy * s, ly = dx * s + dy * c
    return abs(lx) <= t.width / 2 && abs(ly) <= t.height / 2
}

/// Does an object's rotated box overlap a lasso polygon? (corner-in-poly ∪ poly-vertex-in-rect ∪ edge cross)
public func rotatedRectIntersectsPolygon(_ t: Transform, _ polygon: [Point]) -> Bool {
    guard polygon.count >= 3 else { return false }
    let cs = corners(of: t)
    if cs.contains(where: { pointInPolygon($0, polygon) }) { return true }
    if polygon.contains(where: { pointInRotatedRect($0, t) }) { return true }
    for i in 0..<cs.count {
        let a = cs[i], b = cs[(i + 1) % cs.count]
        for j in 0..<polygon.count {
            if segmentsIntersect(a, b, polygon[j], polygon[(j + 1) % polygon.count]) { return true }
        }
    }
    return false
}

// MARK: - Move / resize / rotate (operating on the model's scalar Transform)

public func translate(_ t: Transform, dx: Double, dy: Double) -> Transform {
    Transform(x: t.x + dx, y: t.y + dy, width: t.width, height: t.height, rotation: t.rotation)
}

public func rotate(_ t: Transform, by angle: Double) -> Transform {
    Transform(x: t.x, y: t.y, width: t.width, height: t.height, rotation: t.rotation + angle)
}

public enum ResizeHandle: Sendable, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// Resize from a handle (delta in canvas coords; defined for the axis-aligned case), keeping the
/// opposite edge/corner fixed.
public func resize(_ t: Transform, handle: ResizeHandle, dx: Double, dy: Double) -> Transform {
    var x = t.x, y = t.y, w = t.width, h = t.height
    switch handle {
    case .topLeft, .left, .bottomLeft: x += dx; w -= dx       // left edge moves; right edge fixed
    case .topRight, .right, .bottomRight: w += dx             // right edge moves; left fixed
    case .top, .bottom: break
    }
    switch handle {
    case .topLeft, .top, .topRight: y += dy; h -= dy          // top edge moves; bottom fixed
    case .bottomLeft, .bottom, .bottomRight: h += dy          // bottom moves; top fixed
    case .left, .right: break
    }
    return Transform(x: x, y: y, width: w, height: h, rotation: t.rotation)
}

// MARK: - Coordinate mapping (canvas ↔ view, given the scroll view's offset & zoom)

public func canvasToView(_ p: Point, contentOffset o: Point, zoomScale z: Double) -> Point {
    Point(x: p.x * z - o.x, y: p.y * z - o.y)
}
public func viewToCanvas(_ p: Point, contentOffset o: Point, zoomScale z: Double) -> Point {
    Point(x: (p.x + o.x) / z, y: (p.y + o.y) / z)
}

// MARK: - §5.2 paging logic

/// Grow the page by one screen-height when the viewport nears the bottom, capped at `cap` screens.
public func autoExtend(contentBottomY: Double, currentExtentY: Double, screenHeight: Double, cap: Int = 4)
    -> (newExtentY: Double, didExtend: Bool) {
    let maxExtent = Double(cap) * screenHeight
    let nearBottom = contentBottomY >= currentExtentY - screenHeight * 0.5
    guard nearBottom, currentExtentY < maxExtent else { return (currentExtentY, false) }
    let newExtent = min(currentExtentY + screenHeight, maxExtent)
    return (newExtent, newExtent > currentExtentY)
}

public enum PanIntent: Equatable, Sendable { case scroll, pageForward, pageBack, tap }

/// Classify a finger pan: a firm, direction-locked horizontal drag/flick pages (right-to-left =
/// forward); a small displacement is a tap; otherwise it scrolls.
public func classifyPan(dx: Double, dy: Double, vx: Double, vy: Double, pageWidth: Double,
                        tapThreshold: Double = 10, distanceFraction: Double = 0.25, velocityThreshold: Double = 800)
    -> PanIntent {
    if abs(dx) < tapThreshold && abs(dy) < tapThreshold { return .tap }
    let horizontalDominant = abs(dx) > abs(dy)
    let firm = abs(dx) > distanceFraction * pageWidth || abs(vx) > velocityThreshold
    guard horizontalDominant && firm else { return .scroll }
    return dx < 0 ? .pageForward : .pageBack
}
