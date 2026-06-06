import UIKit
import PencilKit
import InkLabKit

/// The canvas surface (ADR 0005): a paper background, PencilKit ink (pencil-only), and a UIKit object
/// overlay driven by the InkLabDoc journal. SwiftUI provides the chrome (toolbar, command bar) and
/// drives this via `apply(...)` and the public actions.
final class CanvasViewController: UIViewController {
    private let store = JournalStore()
    private let recognizer = DefaultRecognizerStack.make()

    private let paperView = PaperView()
    private let canvasView = PKCanvasView()
    private let overlay = ObjectOverlayView()
    private let lassoLayer = CAShapeLayer()
    private var lassoPoints: [CGPoint] = []
    private var lassoGesture: UIPanGestureRecognizer!
    private var insertOffset: CGFloat = 0

    /// Transient status messages (e.g. lasso/recognition feedback) surfaced by the SwiftUI chrome.
    var onStatus: ((String) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        for v in [paperView, canvasView, overlay] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: view.topAnchor),
                v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }
        canvasView.drawingPolicy = .pencilOnly
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.onObjectMoved = { [weak self] id, t in self?.commitMove(id, t) }

        lassoLayer.strokeColor = UIColor.systemBlue.cgColor
        lassoLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        lassoLayer.lineWidth = 1.5
        lassoLayer.lineDashPattern = [5, 4]
        overlay.layer.addSublayer(lassoLayer)

        lassoGesture = UIPanGestureRecognizer(target: self, action: #selector(handleLasso(_:)))
        lassoGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                          NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        lassoGesture.isEnabled = false
        overlay.addGestureRecognizer(lassoGesture)

        canvasView.tool = PKInkingTool(.pen, color: .label, width: 4)
        overlay.apply(projectionDiff(old: nil, new: store.page), page: store.page)
    }

    // MARK: - Driven by SwiftUI

    func apply(paper: PaperType, penColor: UIColor, penWidth: CGFloat, tool: CanvasTool) {
        paperView.paper = paper
        switch tool {
        case .pen:
            canvasView.tool = PKInkingTool(.pen, color: penColor, width: penWidth)
            setLasso(false)
        case .highlighter:
            canvasView.tool = PKInkingTool(.marker, color: penColor.withAlphaComponent(0.3), width: max(12, penWidth * 4))
            setLasso(false)
        case .eraser:
            canvasView.tool = PKEraserTool(.bitmap)
            setLasso(false)
        case .lasso:
            setLasso(true)
        }
    }

    private func setLasso(_ on: Bool) {
        canvasView.drawingGestureRecognizer.isEnabled = !on
        overlay.isLassoMode = on
        lassoGesture.isEnabled = on
    }

    func performUndo() { let before = store.page; store.undo(); refresh(before) }
    func performRedo() { let before = store.page; store.redo(); refresh(before) }

    func addSticky() {
        insertObject(kind: .sticky, payload: .sticky(text: "Sticky", colorHex: "#FFE680"), size: CGSize(width: 160, height: 120))
    }

    /// Insert a deterministic-engine result as a callout object on the page.
    func insertResult(_ text: String) {
        insertObject(kind: .callout, payload: .callout(text: text, sourceObjectIDs: [], provenanceJSON: "{}"),
                     size: CGSize(width: 300, height: 70))
        onStatus?("Added result")
    }

    private func insertObject(kind: ObjectKind, payload: ObjectPayload, size: CGSize) {
        let id = UUID()
        let base = view.bounds.center
        insertOffset = insertOffset >= 120 ? 0 : insertOffset + 24
        let t = Transform(x: Double(base.x - size.width / 2 + insertOffset),
                          y: Double(base.y - size.height / 2 + insertOffset),
                          width: Double(size.width), height: Double(size.height))
        let snapshot = ObjectSnapshot(objectID: id, kind: kind, transform: t,
                                      pageID: store.pageID, createdBy: store.notebookID, payload: payload)
        let before = store.page
        store.perform([.addObject(snapshot: snapshot)])
        refresh(before)
    }

    private func commitMove(_ id: UUID, _ newTransform: Transform) {
        guard let old = store.page.objects[id] else { return }
        let before = store.page
        store.perform([.setTransform(objectID: id, old: old.transform, new: newTransform)])
        refresh(before)
    }

    private func refresh(_ before: PageProjection) {
        overlay.apply(projectionDiff(old: before, new: store.page), page: store.page)
    }

    // MARK: - Lasso

    @objc private func handleLasso(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: overlay)
        switch g.state {
        case .began: lassoPoints = [p]
        case .changed: lassoPoints.append(p); updateLassoLayer()
        case .ended: finishLasso()
        default: lassoPoints = []; lassoLayer.path = nil
        }
    }

    private func updateLassoLayer() {
        let path = UIBezierPath()
        if let first = lassoPoints.first {
            path.move(to: first)
            for pt in lassoPoints.dropFirst() { path.addLine(to: pt) }
        }
        lassoLayer.path = path.cgPath
    }

    private func finishLasso() {
        defer { lassoPoints = []; lassoLayer.path = nil }
        guard lassoPoints.count >= 3 else { return }
        let polygon = lassoPoints.map { Point(x: Double($0.x), y: Double($0.y)) }
        let selected = selectObjects(in: store.page, lasso: polygon)
        if selected.isEmpty {
            onStatus?("Lassoed ink — handwriting recognition runs the on-device spike / cloud fallback")
        } else {
            onStatus?("Selected \(selected.count) object\(selected.count == 1 ? "" : "s")")
        }
    }
}
