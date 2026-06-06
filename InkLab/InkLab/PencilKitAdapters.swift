import PencilKit
import InkLabKit

/// Bridges PencilKit ink into the recognizer's platform-agnostic value types.
enum PencilKitAdapters {
    static func inkStroke(_ stroke: PKStroke) -> InkStroke {
        var points: [InkPoint] = []
        for p in stroke.path {   // PKStrokePath is a collection of PKStrokePoint (control points)
            points.append(InkPoint(x: Double(p.location.x), y: Double(p.location.y),
                                   t: p.timeOffset, force: Double(p.force)))
        }
        return InkStroke(points: points)
    }

    static func strokes(_ drawing: PKDrawing) -> [InkStroke] { drawing.strokes.map(inkStroke) }

    /// Rasterize a region of the drawing for image-based recognizers (Vision / Claude).
    static func raster(_ drawing: PKDrawing, region: CGRect, scale: CGFloat = 2.0) -> RasterImage? {
        guard region.width > 1, region.height > 1 else { return nil }
        let image = drawing.image(from: region, scale: scale)
        guard let data = image.pngData() else { return nil }
        return RasterImage(pngData: data, width: Int(image.size.width * scale), height: Int(image.size.height * scale))
    }
}
