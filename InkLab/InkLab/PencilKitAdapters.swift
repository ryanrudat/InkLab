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
    /// inside the loop while its control points sit just outside it. Only the part that still shows: the
    /// pixel eraser keeps a stroke's whole path and hides what it rubbed out, so a lasso never catches (and
    /// the scan light never traces) ink that was erased.
    static func hitTestPoints(_ stroke: PKStroke) -> [InkPoint] {
        visiblePaths(stroke).flatMap { $0 }
    }

    /// The stroke's visible runs (transform applied): one for an untouched stroke, one per piece the eraser
    /// left of it, none for a crumb with nothing left to show.
    static func visiblePaths(_ stroke: PKStroke) -> [[InkPoint]] {
        let t = stroke.transform
        let ranges: [ClosedRange<CGFloat>?] = stroke.mask == nil ? [nil] : stroke.maskedPathRanges.map { $0 }
        let runs = ranges.map { range in
            stroke.path.interpolatedPoints(in: range, by: .distance(4)).map { p in
                let loc = p.location.applying(t)
                return InkPoint(x: Double(loc.x), y: Double(loc.y), t: p.timeOffset, force: Double(p.force))
            }
        }.filter { !$0.isEmpty }
        if runs.isEmpty, stroke.mask == nil { return [inkStroke(stroke).points] }   // a dot: its one control point
        return runs
    }

    /// Each stroke as `InkGeometry.eraseLeftovers` sees it: what still shows, how big it was before any
    /// erasing, how much of it is left over all its pieces (pieces of one stroke share its whole path), and
    /// when it was written.
    static func inkPieces(_ strokes: [PKStroke]) -> [InkGeometry.InkPiece] {
        func key(_ s: PKStroke) -> Int {
            var h = Hasher()
            h.combine(s.path.creationDate); h.combine(s.path.count)
            if let p = s.path.first { h.combine(p.location.x); h.combine(p.location.y); h.combine(p.timeOffset) }
            return h.finalize()
        }
        func shownRun(_ s: PKStroke) -> CGFloat {
            s.path.count > 1 ? s.maskedPathRanges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } / CGFloat(s.path.count - 1)
                             : (s.maskedPathRanges.isEmpty ? 0 : 1)
        }
        let keys = strokes.enumerated().map { $0.element.mask == nil ? -1 - $0.offset : key($0.element) }
        var shown: [Int: CGFloat] = [:]
        for (s, k) in zip(strokes, keys) where s.mask != nil { shown[k, default: 0] += shownRun(s) }
        return strokes.enumerated().map { i, s in
            let whole = s.mask == nil ? s.renderBounds
                : PKStroke(ink: s.ink, path: s.path, transform: s.transform, mask: nil).renderBounds
            return InkGeometry.InkPiece(bounds: s.renderBounds, whole: whole, shown: min(1, shown[keys[i]] ?? 1),
                                        stroke: keys[i], written: s.path.creationDate)
        }
    }

    /// Indices of the strokes that are only what's left of erased writing (see `InkGeometry.eraseLeftovers`).
    /// Nothing to work out on a page the eraser never cut.
    static func eraseLeftovers(_ strokes: [PKStroke]) -> Set<Int> {
        guard strokes.contains(where: { $0.mask != nil }) else { return [] }
        return InkGeometry.eraseLeftovers(inkPieces(strokes))
    }

    /// The strokes worth reading: everything but erase leftovers.
    static func readable(_ drawing: PKDrawing) -> PKDrawing {
        let leftovers = eraseLeftovers(drawing.strokes)
        guard !leftovers.isEmpty else { return drawing }
        return PKDrawing(strokes: drawing.strokes.indices.filter { !leftovers.contains($0) }.map { drawing.strokes[$0] })
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

extension PencilKitAdapters {
    /// A stroke's rendered path as points on the page (transform applied), one run per piece that still
    /// shows, for drawing over it — the scan light that traces the writing being read. Long runs are thinned
    /// so a whole page stays cheap.
    static func tracePaths(_ stroke: PKStroke) -> [[CGPoint]] {
        visiblePaths(stroke).map { run in
            let pts = run.map { CGPoint(x: $0.x, y: $0.y) }
            guard pts.count > 400 else { return pts }
            let step = pts.count / 400 + 1
            return pts.enumerated().filter { $0.offset % step == 0 || $0.offset == pts.count - 1 }.map(\.element)
        }
    }
}
