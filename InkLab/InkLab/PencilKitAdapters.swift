import PencilKit
import InkLabKit

/// Bridges PencilKit ink into the recognizer's platform-agnostic value types.
enum PencilKitAdapters {
    static func inkStroke(_ stroke: PKStroke) -> InkStroke {
        var points: [InkPoint] = []
        // PencilKit keeps a MOVED stroke's offset in `stroke.transform`, not in its path points — so the
        // raw `p.location` is the stroke's stale, pre-move position. Apply the transform to get the TRUE
        // rendered coordinates; otherwise lasso hit-tests (and recognition) miss any stroke that's been
        // dragged before. For a freshly-drawn stroke the transform is identity, so this is a no-op.
        let t = stroke.transform
        for p in stroke.path {   // PKStrokePath is a collection of PKStrokePoint (control points)
            let loc = p.location.applying(t)
            points.append(InkPoint(x: Double(loc.x), y: Double(loc.y),
                                   t: p.timeOffset, force: Double(p.force)))
        }
        return InkStroke(points: points)
    }

    static func strokes(_ drawing: PKDrawing) -> [InkStroke] { drawing.strokes.map(inkStroke) }

    /// Densely-sampled, transform-applied points along a stroke's RENDERED spline — for lasso hit-testing,
    /// where the sparse B-spline CONTROL points (what `inkStroke` returns) can miss a stroke whose curve is
    /// inside the loop while its control points sit just outside it. Falls back to the control points if
    /// interpolation yields nothing.
    static func hitTestPoints(_ stroke: PKStroke) -> [InkPoint] {
        let t = stroke.transform
        var points: [InkPoint] = []
        for p in stroke.path.interpolatedPoints(by: .distance(4)) {
            let loc = p.location.applying(t)
            points.append(InkPoint(x: Double(loc.x), y: Double(loc.y), t: p.timeOffset, force: Double(p.force)))
        }
        return points.isEmpty ? inkStroke(stroke).points : points
    }

    /// Rasterize a region of the drawing for image-based recognizers (Vision / Claude).
    static func raster(_ drawing: PKDrawing, region: CGRect, scale: CGFloat = 2.0,
                       maxPixels: CGFloat = 3_000_000) -> RasterImage? {
        guard region.width > 1, region.height > 1 else { return nil }
        // Whole-page OCR at a fixed 2× can create tens of megapixels, PNG-compress on the ink run-loop,
        // and exceed the proxy body limit. Preserve 2× for small selections but downscale large regions to
        // a bounded pixel budget. A PencilKit page is never large enough to hit the defensive 0.25 floor.
        let area = region.width * region.height
        let budgetScale = sqrt(maxPixels / max(area, 1))
        let effectiveScale = max(0.25, min(scale, budgetScale))
        let image = drawing.image(from: region, scale: effectiveScale)
        guard let data = image.pngData() else { return nil }
        return RasterImage(pngData: data,
                           width: Int(image.size.width * effectiveScale),
                           height: Int(image.size.height * effectiveScale))
    }
}
