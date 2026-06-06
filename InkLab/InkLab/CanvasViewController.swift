import UIKit
import PencilKit
import InkLabKit

/// The canvas spine (ADR 0005): PencilKit ink (pencil-only) with a UIKit object overlay, the
/// pencil-draws/finger-navigates touch-type partition, and a finger+Pencil lasso that selects
/// objects via InkLabCanvasCore and feeds rasterized regions to InkLabRecognition. Objects are
/// driven by the InkLabDoc journal with global undo.
///
/// SLICE SCOPE: one fixed page, no scroll/zoom/paging yet (Gate A), ink not yet committed into the
/// journal (Gate D). Those are the on-device gates from ADR 0005.
final class CanvasViewController: UIViewController {
    private let store = JournalStore()
    private let recognizer = DefaultRecognizerStack.make()

    private let canvasView = PKCanvasView()
    private let overlay = ObjectOverlayView()
    private let lassoLayer = CAShapeLayer()
    private let statusLabel = UILabel()
    private let toolbar = UIToolbar()

    private var lassoPoints: [CGPoint] = []
    private var lassoGesture: UIPanGestureRecognizer!

    private enum Tool { case pen, lasso }
    private var tool: Tool = .pen { didSet { applyTool() } }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.drawingPolicy = .pencilOnly       // only Apple Pencil draws ink (Gate B)
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        view.addSubview(canvasView)

        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = .clear
        overlay.onObjectMoved = { [weak self] id, t in self?.commitMove(id, t) }
        view.addSubview(overlay)

        for v in [canvasView, overlay] as [UIView] {
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: view.topAnchor),
                v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }

        lassoLayer.strokeColor = UIColor.systemBlue.cgColor
        lassoLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        lassoLayer.lineWidth = 1.5
        lassoLayer.lineDashPattern = [5, 4]
        overlay.layer.addSublayer(lassoLayer)

        // Lasso accepts finger AND Pencil (the confirmed Pencil-lasso mode); enabled only in lasso tool.
        lassoGesture = UIPanGestureRecognizer(target: self, action: #selector(handleLasso(_:)))
        lassoGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                          NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        overlay.addGestureRecognizer(lassoGesture)

        setupChrome()
        applyTool()
        overlay.apply(projectionDiff(old: nil, new: store.page), page: store.page)
    }

    // MARK: Tool state

    private func applyTool() {
        switch tool {
        case .pen:
            canvasView.tool = PKInkingTool(.pen, color: .label, width: 4)
            canvasView.drawingGestureRecognizer.isEnabled = true
            overlay.isLassoMode = false
            lassoGesture.isEnabled = false
        case .lasso:
            canvasView.drawingGestureRecognizer.isEnabled = false  // Pencil draws the lasso, not ink
            overlay.isLassoMode = true
            lassoGesture.isEnabled = true
        }
        penItem.tintColor = (tool == .pen) ? .systemBlue : .secondaryLabel
        lassoItem.tintColor = (tool == .lasso) ? .systemBlue : .secondaryLabel
    }

    // MARK: Lasso

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
        // View coords == canvas coords in this single-page slice. Once Gate A adds native scroll/zoom,
        // map via InkLabCanvasCore.viewToCanvas(_:contentOffset:zoomScale:).
        let polygon = lassoPoints.map { Point(x: Double($0.x), y: Double($0.y)) }
        let selected = selectObjects(in: store.page, lasso: polygon)
        status("Lassoed \(selected.count) object(s)" + (selected.isEmpty ? " — recognizing ink…" : ""))
        if selected.isEmpty, let region = boundingRect(polygon) {
            Task { await recognizeRegion(CGRect(x: region.x, y: region.y, width: region.width, height: region.height)) }
        }
    }

    /// Rasterize the lassoed ink + hand strokes to the recognizer. Concrete providers (MyScript/
    /// Apple Vision/Claude) land during the recognition spike; today they return `.unrecognized`.
    private func recognizeRegion(_ region: CGRect) async {
        let raster = PencilKitAdapters.raster(canvasView.drawing, region: region)
            ?? RasterImage(pngData: Data(), width: 0, height: 0)
        let input = RecognitionInput(
            strokes: PencilKitAdapters.strokes(canvasView.drawing),
            raster: raster,
            region: Rect(x: Double(region.minX), y: Double(region.minY), width: Double(region.width), height: Double(region.height)),
            domainHint: .math,
            session: SessionContext(isOnline: true, userKind: .adult, cloudAIConsentGranted: true)
        )
        let result = try? await recognizer.recognize(input)
        if let r = result, !r.readAs.isEmpty { status("Recognized: \(r.readAs)") }
        else { status("Recognition not wired yet (providers land in the spike)") }
    }

    // MARK: Journal actions

    private func addSticky() {
        let id = UUID()
        let c = view.bounds.center
        let t = Transform(x: Double(c.x) - 80, y: Double(c.y) - 60, width: 160, height: 120)
        let snapshot = ObjectSnapshot(objectID: id, kind: .sticky, transform: t,
                                      pageID: store.pageID, createdBy: store.notebookID,
                                      payload: .sticky(text: "Sticky", colorHex: "#FFE680"))
        let before = store.page
        store.perform([.addObject(snapshot: snapshot)])
        overlay.apply(projectionDiff(old: before, new: store.page), page: store.page)
    }

    private func commitMove(_ id: UUID, _ newTransform: Transform) {
        guard let old = store.page.objects[id] else { return }
        let before = store.page
        store.perform([.setTransform(objectID: id, old: old.transform, new: newTransform)])
        overlay.apply(projectionDiff(old: before, new: store.page), page: store.page)
    }

    @objc private func undoTapped() {
        let before = store.page
        store.undo()
        overlay.apply(projectionDiff(old: before, new: store.page), page: store.page)
        status(store.canUndo ? "Undid" : "Nothing left to undo")
    }

    // MARK: Chrome

    private lazy var penItem = UIBarButtonItem(image: UIImage(systemName: "pencil.tip"), style: .plain, target: self, action: #selector(selectPen))
    private lazy var lassoItem = UIBarButtonItem(image: UIImage(systemName: "lasso"), style: .plain, target: self, action: #selector(selectLasso))
    private lazy var stickyItem = UIBarButtonItem(image: UIImage(systemName: "note.text.badge.plus"), style: .plain, target: self, action: #selector(addStickyTapped))
    private lazy var undoItem = UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.backward"), style: .plain, target: self, action: #selector(undoTapped))

    private func setupChrome() {
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.items = [penItem, lassoItem, stickyItem, UIBarButtonItem(systemItem: .flexibleSpace), undoItem]
        view.addSubview(toolbar)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.text = "Pencil draws · finger drags objects · lasso tool selects · undo via the journal"
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
    }

    @objc private func selectPen() { tool = .pen }
    @objc private func selectLasso() { tool = .lasso }
    @objc private func addStickyTapped() { addSticky() }
    private func status(_ s: String) { statusLabel.text = s }
}
