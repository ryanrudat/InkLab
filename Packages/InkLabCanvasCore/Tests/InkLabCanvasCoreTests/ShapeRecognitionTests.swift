import XCTest
@testable import InkLabCanvasCore
import InkLabRecognition   // Point

final class ShapeRecognitionTests: XCTestCase {

    // MARK: - Synthetic stroke generators

    /// A straight line with a little jitter, sampled at `n` points.
    private func line(from a: Point, to b: Point, n: Int = 40, jitter: Double = 0) -> [Point] {
        (0...n).map { i in
            let t = Double(i) / Double(n)
            let j = jitter == 0 ? 0 : (Double((i * 37) % 7) - 3) / 3 * jitter   // deterministic wobble
            return Point(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y) + j)
        }
    }

    /// A closed loop on an axis-aligned ellipse (circle when rx==ry).
    private func ellipse(cx: Double, cy: Double, rx: Double, ry: Double, n: Int = 48) -> [Point] {
        (0...n).map { i in
            let a = 2 * Double.pi * Double(i) / Double(n)
            return Point(x: cx + rx * cos(a), y: cy + ry * sin(a))
        }
    }

    /// Trace a closed polygon's perimeter, sampling each edge.
    private func polygonPath(_ verts: [Point], perEdge: Int = 12) -> [Point] {
        var pts: [Point] = []
        for i in 0..<verts.count {
            let a = verts[i], b = verts[(i + 1) % verts.count]
            for k in 0..<perEdge {
                let t = Double(k) / Double(perEdge)
                pts.append(Point(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y)))
            }
        }
        pts.append(verts[0])   // close it
        return pts
    }

    // MARK: - Lines

    func test_straightLine_snapsToLine() {
        guard case .line(let a, let b)? = recognizeShape(line(from: Point(x: 0, y: 0), to: Point(x: 200, y: 90), jitter: 2)) else {
            return XCTFail("expected a line")
        }
        XCTAssertEqual(a.x, 0, accuracy: 6); XCTAssertEqual(b.x, 200, accuracy: 6)
    }

    func test_nearHorizontalLine_snapsFlat() {
        guard case .line(let a, let b)? = recognizeShape(line(from: Point(x: 0, y: 0), to: Point(x: 200, y: 6))) else {
            return XCTFail("expected a line")
        }
        XCTAssertEqual(a.y, b.y, accuracy: 0.001, "near-horizontal line should snap to exactly horizontal")
    }

    func test_nearVerticalLine_snapsStraightUp() {
        guard case .line(let a, let b)? = recognizeShape(line(from: Point(x: 0, y: 0), to: Point(x: 6, y: 200))) else {
            return XCTFail("expected a line")
        }
        XCTAssertEqual(a.x, b.x, accuracy: 0.001, "near-vertical line should snap to exactly vertical")
    }

    // MARK: - Ellipse / circle

    func test_circle_snapsToCircle() {
        guard case .ellipse(let c, let rx, let ry)? = recognizeShape(ellipse(cx: 50, cy: 50, rx: 40, ry: 40)) else {
            return XCTFail("expected an ellipse")
        }
        XCTAssertEqual(c.x, 50, accuracy: 3); XCTAssertEqual(c.y, 50, accuracy: 3)
        XCTAssertEqual(rx, ry, accuracy: 0.001, "a round loop should snap to a true circle")
        XCTAssertEqual(rx, 40, accuracy: 4)
    }

    func test_wideEllipse_keepsTwoRadii() {
        guard case .ellipse(_, let rx, let ry)? = recognizeShape(ellipse(cx: 0, cy: 0, rx: 90, ry: 40)) else {
            return XCTFail("expected an ellipse")
        }
        XCTAssertGreaterThan(rx, ry + 10, "a clearly elliptical loop should keep distinct radii")
    }

    // MARK: - Polygons

    func test_rectangle_snapsToFourAxisAlignedCorners() {
        let r = polygonPath([Point(x: 0, y: 0), Point(x: 120, y: 0), Point(x: 120, y: 70), Point(x: 0, y: 70)])
        guard case .polygon(let v, let closed)? = recognizeShape(r) else { return XCTFail("expected a polygon") }
        XCTAssertTrue(closed)
        XCTAssertEqual(v.count, 4, "a box should resolve to four corners")
        // Axis-aligned: every edge is horizontal or vertical.
        for i in 0..<v.count {
            let a = v[i], b = v[(i + 1) % v.count]
            XCTAssertTrue(abs(a.x - b.x) < 0.001 || abs(a.y - b.y) < 0.001, "edges should be axis-aligned")
        }
    }

    func test_triangle_snapsToThreeCorners() {
        let tri = polygonPath([Point(x: 0, y: 0), Point(x: 120, y: 0), Point(x: 60, y: 100)])
        guard case .polygon(let v, _)? = recognizeShape(tri) else { return XCTFail("expected a polygon") }
        XCTAssertEqual(v.count, 3)
    }

    // MARK: - Arrow

    func test_arrow_detected() {
        // Shaft 0→200 along x, then a short barb bending back/up.
        var pts = line(from: Point(x: 0, y: 0), to: Point(x: 200, y: 0), n: 40)
        pts += [Point(x: 188, y: 9), Point(x: 180, y: 16)]   // barb
        guard case .arrow(let a, let b)? = recognizeShape(pts) else { return XCTFail("expected an arrow") }
        XCTAssertEqual(a.x, 0, accuracy: 8)
        XCTAssertEqual(b.x, 200, accuracy: 12, "arrow tip should be at the shaft end, not the barb end")
    }

    // MARK: - Negatives / gating

    func test_freehandSquiggle_isNotSnapped() {
        // A wavy open curve — not a line, not closed, not an arrow.
        let squiggle = (0...60).map { i -> Point in
            let x = Double(i) * 3
            return Point(x: x, y: 30 * sin(Double(i) / 3))
        }
        XCTAssertNil(recognizeShape(squiggle))
    }

    func test_lineWithEndDwell_stillSnapsToLine() {
        // A held pencil appends a cluster of near-identical samples at the end of the stroke; recognition
        // must still see a clean line (dedupe/resample neutralize the dwell).
        var pts = line(from: Point(x: 0, y: 0), to: Point(x: 200, y: 70))
        let end = pts.last!
        pts += (0..<40).map { _ in Point(x: end.x + 1.5, y: end.y - 1.0) }   // dwell wobble
        guard case .line? = recognizeShape(pts) else { return XCTFail("line + end-dwell should still be a line") }
    }

    func test_circleWithEndDwell_stillSnapsToCircle() {
        var pts = ellipse(cx: 60, cy: 60, rx: 45, ry: 45)
        let end = pts.last!
        pts += (0..<40).map { _ in Point(x: end.x, y: end.y) }               // held at the closing point
        guard case .ellipse? = recognizeShape(pts) else { return XCTFail("circle + end-dwell should still be a circle") }
    }

    func test_tinyStroke_isIgnored() {
        XCTAssertNil(recognizeShape(line(from: Point(x: 0, y: 0), to: Point(x: 5, y: 3))))
    }

    func test_optionsGate_disablingLinesSuppressesIt() {
        let l = line(from: Point(x: 0, y: 0), to: Point(x: 200, y: 90))
        XCTAssertNil(recognizeShape(l, options: ShapeOptions(lines: false, arrows: false, ellipses: true, polygons: true)))
    }

    func test_optionsGate_disablingEllipsesSuppressesIt() {
        let c = ellipse(cx: 50, cy: 50, rx: 40, ry: 40)
        XCTAssertNil(recognizeShape(c, options: ShapeOptions(lines: true, arrows: true, ellipses: false, polygons: false)))
    }
}
