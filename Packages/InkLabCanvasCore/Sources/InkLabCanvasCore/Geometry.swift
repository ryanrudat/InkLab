import Foundation
import InkLabRecognition   // Point, Rect

// Lightweight vector helpers on the recognizer's Point (so canvas geometry feeds RecognitionInput).
extension Point {
    static func - (a: Point, b: Point) -> Point { Point(x: a.x - b.x, y: a.y - b.y) }
    static func + (a: Point, b: Point) -> Point { Point(x: a.x + b.x, y: a.y + b.y) }
}

/// Ray-casting point-in-polygon test (polygon as an ordered ring of vertices).
public func pointInPolygon(_ p: Point, _ polygon: [Point]) -> Bool {
    guard polygon.count >= 3 else { return false }
    var inside = false
    var j = polygon.count - 1
    for i in 0..<polygon.count {
        let a = polygon[i], b = polygon[j]
        if (a.y > p.y) != (b.y > p.y),
           p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
            inside.toggle()
        }
        j = i
    }
    return inside
}

private func cross(_ o: Point, _ a: Point, _ b: Point) -> Double {
    (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
}

/// Do segments p1p2 and p3p4 properly cross? (General-position test — sufficient for lasso work.)
public func segmentsIntersect(_ p1: Point, _ p2: Point, _ p3: Point, _ p4: Point) -> Bool {
    let d1 = cross(p3, p4, p1), d2 = cross(p3, p4, p2)
    let d3 = cross(p1, p2, p3), d4 = cross(p1, p2, p4)
    return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))
}

/// Does the open polyline `points` cross any edge of `polygon`?
public func polylineIntersectsPolygon(_ points: [Point], _ polygon: [Point]) -> Bool {
    guard points.count >= 2, polygon.count >= 2 else { return false }
    for i in 0..<(points.count - 1) {
        for j in 0..<polygon.count {
            if segmentsIntersect(points[i], points[i + 1], polygon[j], polygon[(j + 1) % polygon.count]) { return true }
        }
    }
    return false
}

public enum LassoMode: Sendable { case contains, intersects }

/// Is a stroke (its sampled path points) selected by a lasso polygon?
/// `.contains` = the whole stroke is inside; `.intersects` = it touches/crosses the lasso.
public func strokeHitTest(strokePoints points: [Point], lasso: [Point], mode: LassoMode) -> Bool {
    guard !points.isEmpty, lasso.count >= 3 else { return false }
    switch mode {
    case .contains:
        return points.allSatisfy { pointInPolygon($0, lasso) }
    case .intersects:
        if points.contains(where: { pointInPolygon($0, lasso) }) { return true }
        return polylineIntersectsPolygon(points, lasso)
    }
}

/// Axis-aligned bounding rectangle of a set of points (e.g. a selection / lasso region).
public func boundingRect(_ points: [Point]) -> Rect? {
    guard let first = points.first else { return nil }
    var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
    for p in points { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
    return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}
