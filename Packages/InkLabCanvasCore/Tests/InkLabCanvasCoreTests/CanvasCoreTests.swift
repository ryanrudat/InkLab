import XCTest
@testable import InkLabCanvasCore
import InkLabRecognition   // Point, Rect
import InkLabDoc           // Transform, ObjectSnapshot, PageProjection, FractionalIndex, ObjectPayload

final class CanvasCoreTests: XCTestCase {

    // Fixed page/author UUIDs so the same (id, transform, …) reproduces an EQUAL snapshot.
    let fixedPage = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    let fixedAuthor = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
    func obj(_ id: UUID, _ t: Transform, deleted: Bool = false, z: String = "m") -> ObjectSnapshot {
        ObjectSnapshot(objectID: id, kind: .sticky, transform: t, z: FractionalIndex(z),
                       pageID: fixedPage, createdBy: fixedAuthor, payload: .sticky(text: "n", colorHex: "#fff"),
                       isDeleted: deleted)
    }
    let square = [Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 10, y: 10), Point(x: 0, y: 10)]

    // MARK: - Lasso hit-testing

    func test_pointInPolygon() {
        XCTAssertTrue(pointInPolygon(Point(x: 5, y: 5), square))
        XCTAssertFalse(pointInPolygon(Point(x: 15, y: 5), square))
    }

    func test_strokeHitTest_containsVsIntersects() {
        let inside = [Point(x: 2, y: 2), Point(x: 4, y: 4), Point(x: 6, y: 6)]
        let straddling = [Point(x: 5, y: 5), Point(x: 50, y: 50)]
        XCTAssertTrue(strokeHitTest(strokePoints: inside, lasso: square, mode: .contains))
        XCTAssertFalse(strokeHitTest(strokePoints: straddling, lasso: square, mode: .contains))
        XCTAssertTrue(strokeHitTest(strokePoints: straddling, lasso: square, mode: .intersects))
        let outside = [Point(x: 90, y: 90), Point(x: 95, y: 95)]
        XCTAssertFalse(strokeHitTest(strokePoints: outside, lasso: square, mode: .intersects))
    }

    func test_rotatedRect_selection() {
        // a small box at origin, rotated 45°, overlaps a lasso around the origin
        let t = Transform(x: -5, y: -5, width: 10, height: 10, rotation: .pi / 4)
        let lasso = [Point(x: -20, y: -20), Point(x: 20, y: -20), Point(x: 20, y: 20), Point(x: -20, y: 20)]
        XCTAssertTrue(rotatedRectIntersectsPolygon(t, lasso))
        let far = Transform(x: 100, y: 100, width: 10, height: 10, rotation: .pi / 4)
        XCTAssertFalse(rotatedRectIntersectsPolygon(far, lasso))
    }

    // MARK: - Transform math

    func test_resize_keepsOppositeCornerFixed() {
        let t = Transform(x: 0, y: 0, width: 100, height: 80)
        let resized = resize(t, handle: .topLeft, dx: 10, dy: 20)
        // bottom-right corner (index 2) must be unchanged
        XCTAssertEqual(corners(of: t)[2], corners(of: resized)[2])
        XCTAssertEqual(resized.width, 90)
        XCTAssertEqual(resized.height, 60)
    }

    func test_rotate_inverseIsIdentity() {
        let t = Transform(x: 1, y: 2, width: 3, height: 4, rotation: 0.5)
        XCTAssertEqual(rotate(rotate(t, by: 1.1), by: -1.1).rotation, t.rotation, accuracy: 1e-12)
    }

    func test_coordinateMapping_roundTrips() {
        let p = Point(x: 123.5, y: -42.0)
        for z in [1.0, 2.5, 10.0] {
            let o = Point(x: 30, y: 70)
            let back = viewToCanvas(canvasToView(p, contentOffset: o, zoomScale: z), contentOffset: o, zoomScale: z)
            XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
            XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
        }
    }

    // MARK: - Paging logic (§5.2)

    func test_autoExtend_growsAndCaps() {
        // near the bottom, below cap -> grows by one screen
        let (e1, did1) = autoExtend(contentBottomY: 900, currentExtentY: 1000, screenHeight: 800, cap: 4)
        XCTAssertEqual(e1, 1800); XCTAssertTrue(did1)
        // at the cap -> no growth
        let (e2, did2) = autoExtend(contentBottomY: 3200, currentExtentY: 3200, screenHeight: 800, cap: 4)
        XCTAssertEqual(e2, 3200); XCTAssertFalse(did2)
        // not near the bottom -> no growth
        let (_, did3) = autoExtend(contentBottomY: 100, currentExtentY: 1000, screenHeight: 800)
        XCTAssertFalse(did3)
    }

    func test_classifyPan() {
        XCTAssertEqual(classifyPan(dx: -200, dy: 10, vx: -100, vy: 0, pageWidth: 700), .pageForward)
        XCTAssertEqual(classifyPan(dx: 200, dy: 10, vx: 100, vy: 0, pageWidth: 700), .pageBack)
        XCTAssertEqual(classifyPan(dx: 20, dy: 300, vx: 0, vy: 900, pageWidth: 700), .scroll)
        XCTAssertEqual(classifyPan(dx: 5, dy: 5, vx: 0, vy: 0, pageWidth: 700), .tap)
        // gentle, slow horizontal drag should scroll, not page
        XCTAssertEqual(classifyPan(dx: -100, dy: 10, vx: -50, vy: 0, pageWidth: 700), .scroll)
    }

    // MARK: - Page selection & projection diff

    func test_selectObjects() {
        let a = UUID(), b = UUID()
        let page = PageProjection(id: UUID(), objects: [
            a: obj(a, Transform(x: 2, y: 2, width: 4, height: 4)),       // inside the unit square lasso
            b: obj(b, Transform(x: 100, y: 100, width: 4, height: 4)),   // far away
        ])
        XCTAssertEqual(selectObjects(in: page, lasso: square), [a])
    }

    func test_projectionDiff() {
        let a = UUID(), b = UUID(), c = UUID()
        let t1 = Transform(x: 0, y: 0, width: 10, height: 10)
        let t2 = Transform(x: 5, y: 5, width: 10, height: 10)
        let old = PageProjection(id: UUID(), objects: [a: obj(a, t1), c: obj(c, t1)])
        let new = PageProjection(id: UUID(), objects: [a: obj(a, t2), b: obj(b, t1)])  // A moved, B added, C gone
        let ops = projectionDiff(old: old, new: new)
        XCTAssertTrue(ops.contains(.updateTransform(a, t2)))
        XCTAssertTrue(ops.contains(.add(obj(b, t1))))
        XCTAssertTrue(ops.contains(.remove(c)))
        XCTAssertEqual(ops.count, 3)
    }

    func test_projectionDiff_tombstoneIsRemoval() {
        let a = UUID()
        let t = Transform(x: 0, y: 0, width: 10, height: 10)
        let old = PageProjection(id: UUID(), objects: [a: obj(a, t)])
        let new = PageProjection(id: UUID(), objects: [a: obj(a, t, deleted: true)])
        XCTAssertEqual(projectionDiff(old: old, new: new), [.remove(a)])
    }
}
