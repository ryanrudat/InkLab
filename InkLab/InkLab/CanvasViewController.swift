import UIKit
import PencilKit
import InkLabKit

/// The canvas surface (ADR 0005): a paper background, PencilKit ink (pencil-only), and a UIKit object
/// overlay driven by the InkLabDoc journal. SwiftUI provides the chrome (toolbar, command bar) and
/// drives this via `apply(...)` and the public actions.
final class CanvasViewController: UIViewController, PKCanvasViewDelegate {
    /// The notebook this canvas edits — set by the SwiftUI bridge before the view loads so the journal
    /// + ink persist under a stable per-notebook directory (survives relaunch).
    var notebookID = UUID()
    /// Durable per-notebook storage (op log + ink blobs). Lazily created so `notebookID` is set first.
    private lazy var storage: JournalStorage = FileJournalStorage(notebookID: notebookID)
    private lazy var store = JournalStore(notebookID: notebookID, storage: storage)
    /// On-device Apple Vision (free, offline) — used for the cheap auto-scan first pass.
    private let recognizer: any InkRecognizer = AppRecognizer.make()
    /// Cloud recognizer (Claude vision via the proxy) — reads messy handwriting + the "@" symbol far
    /// better than Apple Vision. Used for the explicit Recognize button and to escalate auto-scans.
    private var cloudRecognizer = ClaudeVisionRecognizer()

    private let paperView = PaperView()
    private let canvasView = PKCanvasView()
    private let overlay = ObjectOverlayView()
    private let lassoLayer = CAShapeLayer()
    private var lassoPoints: [CGPoint] = []
    private let liveLassoPath = UIBezierPath()
    /// Gesture recognizers can deliver several sub-point moves per frame. Keeping only spatially meaningful
    /// samples bounds final polygon hit-testing and avoids rebuilding an ever-longer path on every callback.
    private let lassoSampleSpacing: CGFloat = 4
    // Created eagerly (not in viewDidLoad) so `apply(...)` — which SwiftUI calls from
    // makeUIViewController, BEFORE the view loads — can safely toggle it without a nil crash.
    private let lassoGesture = UIPanGestureRecognizer()
    /// Draw-and-hold shape snapping. We observe PencilKit's OWN drawing gesture (a target on
    /// `canvasView.drawingGestureRecognizer`) instead of a competing recognizer — PKCanvasView won't
    /// reliably run a separate gesture simultaneously with drawing, which is why the first attempt never
    /// fired. A stationary timer turns "held still ~0.5s mid-stroke" into an arm; the finished stroke is
    /// then snapped to a clean shape.
    private var snapShapesEnabled = true
    private var shapeSnapArmed = false
    private var holdCheck: DispatchWorkItem?
    private var lastHoldPoint: CGPoint = .zero
    private var currentTool: CanvasTool = .pen
    private let shapeHoldSeconds: TimeInterval = 0.5
    private let shapeHoldJitter: CGFloat = 6        // live-gesture: movement under this (pt) still counts as "holding"
    private let shapeDwellRadius: CGFloat = 10      // stroke-sample fallback: end-dwell wander tolerance (pt)
    private var insertOffset: CGFloat = 0
    private var allowsFingerDrawing = true
    /// Bounding box of the most recent lasso, so Recognize can read just that selection (cleared when
    /// new ink is drawn).
    private var lastLassoRect: CGRect?
    // Lasso SELECTION, for direct manipulation (drag-to-move). Captured in `finishLasso`; a single-finger
    // drag that BEGINS inside the selection moves it instead of starting a new loop. Stroke indices index
    // into the live drawing and stay valid because drawing any new ink clears the selection (reindexing).
    private var selectedObjectIDs: Set<UUID> = []
    private var selectedStrokeIndices: [Int] = []
    private var selectionMarquee: [CGPoint] = []        // the closed loop points (so the marquee can travel with a move)
    // Active move-drag scratch.
    private var movingSelection = false
    private var moveStart: CGPoint = .zero
    private var moveObjectStart: [UUID: Transform] = [:]   // each selected object's transform at drag start
    private var moveInkBefore: PKDrawing?                   // drawing snapshot at drag start (for one-step undo)
    /// During an ink drag the selected strokes are lifted onto this cheap snapshot layer and ONLY the layer
    /// is translated per frame (the heavy PKDrawing rebuild happens once, on release). Without it,
    /// reassigning `canvasView.drawing` every touch-move re-rendered the whole page and made drags lag.
    private var dragInkPreviewLayer: CALayer?
    private var hasLassoSelection: Bool { !selectedObjectIDs.isEmpty || !selectedStrokeIndices.isEmpty }
    /// Native edit menu (Cut / Copy / Delete / Paste) shown on a tap inside a lasso selection.
    private lazy var editMenuInteraction = UIEditMenuInteraction(delegate: self)
    /// True while a make-real generation is in flight (only one WKWebView spins up at a time).
    private var isGenerating = false
    /// Pending make-real prompts (e.g. several "@" commands written at once) — run one after another.
    private var makeRealQueue: [(prompt: String, pageID: UUID)] = []
    /// Consent session for make-real, mirrored from settings via `apply(...)`. Defaults to not-consented.
    private var makeRealSession = MakeRealSession(isOnline: true, userKind: "adult", aiConsentGranted: false, ageVerified: true)
    /// Tutor sessions with a request in flight (one tutor message at a time per session), and the
    /// student replies waiting behind it (ink written while the tutor was still answering).
    private var tutorBusy: Set<UUID> = []
    private var pendingTutorReplies: [UUID: [(text: String, wantsHint: Bool, page: UUID)]] = [:]
    /// "Write on the page": the highlighted space where the student's next ink is read as their reply
    /// (one at a time, on the page it was opened on).
    private var tutorWriteZone: (session: UUID, page: UUID, rect: CGRect, view: TutorWriteZoneView)?

    // Automatic in-canvas "@" detection: after a writing pause, OCR the NEW strokes; if they read as
    // an "@" command, run it and erase that ink. `consumedStrokeCount` marks how many strokes (from
    // the front) have already been examined, so we never re-OCR or re-run old ink.
    private var autoCommandsEnabled = true
    private var consumedStrokeCount = 0
    private var pendingAutoScan: DispatchWorkItem?
    private var autoScanBusy = false
    private var autoScanNeedsRetry = false
    /// Debounced ink-blob save (coalesces rapid strokes into one write per page).
    private var pendingInkSave: DispatchWorkItem?
    /// Recognition and generation are unstructured async work. Track every task so dismantling the
    /// canvas cannot leave a stale controller mutating the same notebook after it is reopened.
    private var activeAsyncTasks: [UUID: Task<Void, Never>] = [:]
    private var isDismissing = false

    // Unified back/forward history for the toolbar undo/redo. Every user action — a handwriting change
    // OR a journal transaction (object insert/edit/move/delete) — is ONE ordered step, so the buttons
    // step to the EXACT previous/next thing the user created, ink and objects interleaved in real order.
    // Ink isn't in the journal yet (never-lose-ink persistence is the GRDB step), so we snapshot the
    // drawing per step here; object ops stay with the journal's own inverse.
    private enum HistoryStep {
        case ink(before: PKDrawing, after: PKDrawing)
        case journal
        /// A compound lasso edit (move / delete / cut / paste): the ink change (a before→after drawing,
        /// if any) and a single object journal transaction (if any) are undone/redone TOGETHER as one
        /// step — so a mixed ink+object edit reverses in a single undo even though ink lives outside the
        /// journal. `hasObjects` says whether to also drive the journal's undo/redo.
        case compound(inkBefore: PKDrawing?, inkAfter: PKDrawing?, hasObjects: Bool)
    }
    private var undoSteps: [HistoryStep] = []
    private var redoSteps: [HistoryStep] = []
    /// The drawing as of the last recorded step — the "before" for the next ink change.
    private var lastDrawing = PKDrawing()
    /// True while we set `canvasView.drawing` ourselves (undo/redo), so the delegate doesn't record it.
    private var isRestoringDrawing = false
    /// Content-signatures of strokes that a programmatic swap (undo/redo/snap/page-load) REMOVED and that
    /// haven't been legitimately restored since. PencilKit commits a `drawing` assignment through an async
    /// render pipeline, so a fast new stroke can be composited onto the PRE-swap drawing — re-introducing a
    /// removed stroke ("undo, rewrite on the same spot, the undone ink returns"). The delegate strips any
    /// of these exact strokes if they reappear, making the resurrection structurally impossible regardless
    /// of render timing. Armed in `setCanvasDrawing`, disarmed once a clean user stroke proves the base
    /// settled (see `canvasViewDrawingDidChange`).
    private var removedStrokeSignatures: Set<Int> = []
    private let maxHistory = 200

    // Multi-page: each page keeps its own ink + per-page undo/redo, swapped on navigation. (Ink isn't
    // persisted yet, so we stash each page's PKDrawing in memory — survives the session, not relaunch.)
    private struct PageState {
        var ink = PKDrawing()
        var undo: [HistoryStep] = []
        var redo: [HistoryStep] = []
        var last = PKDrawing()
        var consumed = 0
    }
    private var savedPages: [UUID: PageState] = [:]
    private let pageHeightMultiple: CGFloat = 3   // each page is N screens tall (two-finger vertical scroll)

    /// Transient status messages (e.g. lasso/recognition feedback) surfaced by the SwiftUI chrome.
    var onStatus: ((String) -> Void)?
    /// Durable storage failures must not disappear with the transient 2.8s status toast. SwiftUI renders
    /// this as a persistent warning until the notebook is closed/reopened or recovery succeeds.
    var onPersistenceWarning: ((String) -> Void)?
    /// Reports (1-based page index, total pages) so the chrome can show a page indicator.
    var onPageChanged: ((Int, Int) -> Void)?
    /// Called on the main actor when Vision produces a transcription to review.
    var onRecognized: ((RecognitionDraft) -> Void)?
    /// Switch the chrome's tool (the tutor's "Write on the page" needs a drawing tool).
    var onSelectTool: ((CanvasTool) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.paper

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
        canvasView.delegate = self
        canvasView.drawingPolicy = allowsFingerDrawing ? .anyInput : .pencilOnly
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.onObjectMoved = { [weak self] id, t in self?.commitMove(id, t) }
        overlay.onWidgetState = { [weak self] id, old, new in self?.commitWidgetState(id, old, new) }
        overlay.onDelete = { [weak self] id in self?.deleteObject(id) }
        overlay.onEditText = { [weak self] id, old, new in self?.editStickyText(id, old, new) }
        overlay.onRecognizeAnnotation = { [weak self] id, image in self?.recognizeAnnotationAndDrive(id, image) }
        overlay.onAnnotationChanged = { [weak self] id, data in self?.enqueueInkData(data ?? Data(), page: id) }
        overlay.annotationProvider = { [weak self] id in self?.loadInkData(page: id) }
        overlay.onTutorReply = { [weak self] id, mode in
            guard let self else { return }
            switch mode {
            case .write: self.openTutorWriteZone(calloutID: id)
            case .type, .fixReading: self.closeTutorWriteZone()   // the note opens its own drop-down box
            }
        }
        overlay.onTutorTyped = { [weak self] id, typed in self?.tutorTyped(typed, calloutID: id) }
        store.onPersistenceError = { [weak self] error in self?.reportPersistenceFailure(error) }

        lassoLayer.strokeColor = UIColor.systemBlue.cgColor
        lassoLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        lassoLayer.lineWidth = 1.5
        lassoLayer.lineDashPattern = [5, 4]
        overlay.layer.addSublayer(lassoLayer)

        lassoGesture.addTarget(self, action: #selector(handleLasso(_:)))
        lassoGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                          NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        lassoGesture.maximumNumberOfTouches = 1   // a lasso is one finger; two fingers scroll / page-swipe
        overlay.addGestureRecognizer(lassoGesture)

        // Tap INSIDE a lasso selection → the native Cut/Copy/Delete/Paste menu. `cancelsTouchesInView=false`
        // so it never steals touches from object interaction (e.g. double-tap-to-edit) in non-lasso mode.
        let selectionTap = UITapGestureRecognizer(target: self, action: #selector(handleSelectionTap(_:)))
        selectionTap.cancelsTouchesInView = false
        overlay.addGestureRecognizer(selectionTap)
        overlay.addInteraction(editMenuInteraction)

        // Draw-and-hold shape snapping: piggy-back on PencilKit's OWN drawing gesture so we reliably see
        // the pencil move/pause during a stroke (a separate recognizer won't run simultaneously with it).
        canvasView.drawingGestureRecognizer.addTarget(self, action: #selector(handleShapeHold(_:)))

        // Scrollable page: two fingers scroll vertically (one finger still draws); contentSize is set in
        // viewDidLayoutSubviews. A two-finger horizontal swipe pages (one finger is reserved for ink).
        canvasView.alwaysBounceVertical = true
        canvasView.showsVerticalScrollIndicator = true
        canvasView.panGestureRecognizer.minimumNumberOfTouches = allowsFingerDrawing ? 2 : 1
        for dir in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handlePageSwipe(_:)))
            swipe.direction = dir
            swipe.numberOfTouchesRequired = 2
            view.addGestureRecognizer(swipe)
        }

        canvasView.tool = PKInkingTool(.pen, color: .label, width: 4)
        overlay.apply(projectionDiff(old: nil, new: store.page), page: store.page)
        notifyPageChanged()

        // Restore this page's persisted ink (objects came from the journal above; ink lives in blobs).
        let restored = loadedInk(store.pageID)
        if !restored.strokes.isEmpty {
            setCanvasDrawing(restored)
            lastDrawing = restored
            consumedStrokeCount = restored.strokes.count
        }

        // Flush pending ink to disk the instant the app suspends/backgrounds — closes the 0.8s debounce
        // window so a home-swipe or OS kill can't drop the latest strokes (never-lose-ink, ADR 0004).
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(flushInkNow), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(flushInkNow), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    /// Typing on the page (a tutor note's box, a sticky) must never happen under the keyboard: leave room
    /// to scroll past the page's end while it's up, and scroll just enough to keep the text in view.
    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let screen = view.window?.windowScene?.screen else { return }
        let keyboard = note.name == UIResponder.keyboardWillHideNotification ? .null : view.convert(end, from: screen.coordinateSpace)
        let overlap = keyboard.isNull ? 0 : max(0, view.bounds.maxY - keyboard.minY)
        canvasView.contentInset.bottom = overlap
        guard overlap > 0, let input = overlay.focusedTextInput else { return }
        let bottom = input.convert(input.bounds, to: view).maxY + 16
        if bottom > keyboard.minY {
            canvasView.setContentOffset(CGPoint(x: canvasView.contentOffset.x, y: canvasView.contentOffset.y + bottom - keyboard.minY), animated: true)
        }
    }

    /// Write the current page's ink synchronously now (app suspending). Object ops already persist immediately.
    @objc private func flushInkNow() {
        pendingInkSave?.cancel()
        saveInkData(canvasView.drawing.dataRepresentation(), page: store.pageID)
    }

    /// SwiftUI calls this only when the representable is permanently dismantled. Cancel in-flight work
    /// before releasing the controller so late cloud/Vision results cannot mutate a reopened notebook.
    func prepareForDismissal() {
        guard !isDismissing else { return }
        isDismissing = true
        for task in activeAsyncTasks.values { task.cancel() }
        activeAsyncTasks.removeAll()
        makeRealQueue.removeAll()
        pendingTutorReplies.removeAll()
        closeTutorWriteZone()
        for case let placeholder as DesigningPlaceholderView in overlay.subviews {
            placeholder.stop()
            placeholder.removeFromSuperview()
        }
        cancelDebouncedWorkAndFlushInk()
    }

    /// A temporary disappearance (for example a presented sheet) still closes the ink debounce window,
    /// but must not mark the controller permanently dismissed or cancel useful in-flight recognition.
    private func cancelDebouncedWorkAndFlushInk() {
        pendingInkSave?.cancel(); pendingInkSave = nil
        pendingAutoScan?.cancel(); pendingAutoScan = nil
        flushInkNow()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelDebouncedWorkAndFlushInk()
    }

    private func startTrackedTask(_ operation: @escaping () async -> Void) {
        guard !isDismissing else { return }
        let id = UUID()
        let task = Task { [weak self] in
            await operation()
            self?.activeAsyncTasks[id] = nil
        }
        activeAsyncTasks[id] = task
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Each page is several screens tall so it scrolls vertically.
        let targetH = max(view.bounds.height * pageHeightMultiple, view.bounds.height)
        if canvasView.contentSize.width != view.bounds.width || canvasView.contentSize.height != targetH {
            canvasView.contentSize = CGSize(width: view.bounds.width, height: targetH)
        }
        // Objects live in content coords; align the overlay's window to the scroll position.
        overlay.bounds = CGRect(origin: canvasView.contentOffset, size: view.bounds.size)
        overlay.updateVisibleContentRect(overlay.bounds)
    }

    /// Keep the object overlay + paper ruling aligned with the scroll position (objects are content-coord).
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === canvasView else { return }
        overlay.bounds = CGRect(origin: scrollView.contentOffset, size: overlay.bounds.size)
        overlay.updateVisibleContentRect(overlay.bounds)
        paperView.contentOffsetY = scrollView.contentOffset.y
    }

    // MARK: - Driven by SwiftUI

    /// Snapshot of the last-applied SwiftUI state, so a redundant `apply(...)` (from an unrelated SwiftUI
    /// re-render — dragging the dock, typing in the command bar, a status toast) is a cheap no-op instead
    /// of reassigning the PencilKit tool / gestures every time (which stuttered the dock drag).
    private struct AppliedState: Equatable {
        var paper: PaperType, penColor: UIColor, penWidth: CGFloat, tool: CanvasTool
        var fingerDrawing: Bool, autoCommands: Bool, snapShapes: Bool, session: MakeRealSession
    }
    private var lastApplied: AppliedState?

    func apply(paper: PaperType, penColor: UIColor, penWidth: CGFloat, tool: CanvasTool, fingerDrawing: Bool, autoCommands: Bool,
               snapShapesOnHold: Bool, makeRealSession: MakeRealSession) {
        let incoming = AppliedState(paper: paper, penColor: penColor, penWidth: penWidth, tool: tool,
                                    fingerDrawing: fingerDrawing, autoCommands: autoCommands,
                                    snapShapes: snapShapesOnHold, session: makeRealSession)
        guard incoming != lastApplied else { return }   // nothing changed — skip the UIKit reconfiguration
        lastApplied = incoming
        paperView.paper = paper
        allowsFingerDrawing = fingerDrawing
        autoCommandsEnabled = autoCommands
        snapShapesEnabled = snapShapesOnHold
        currentTool = tool
        self.makeRealSession = makeRealSession
        // Mirror the Eraser tool onto generated widgets: a Pencil should rub out a widget's annotation ink
        // (just like it erases the page) rather than draw red ink on it.
        overlay.setPencilErasesAnnotations(tool == .eraser)
        if tool != .lasso { canvasView.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly }
        // Pencil mode: one finger scrolls. Finger-draw mode: one finger draws, so scrolling needs two.
        canvasView.panGestureRecognizer.minimumNumberOfTouches = fingerDrawing ? 2 : 1
        // Shape-snapping only applies while drawing (pen/highlighter). If it was just turned off or the
        // tool changed mid-hold, drop any pending arm + timer so a stale arm can't snap a later stroke.
        if !(snapShapesOnHold && (tool == .pen || tool == .highlighter)) {
            shapeSnapArmed = false; holdCheck?.cancel(); holdCheck = nil
        }
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
        if !on { clearLassoSelection() }   // leaving lasso mode drops any armed region + marquee
    }

    // MARK: - Unified undo / redo (the toolbar back/forward)

    func performUndo() {
        guard let step = undoSteps.popLast() else { return }
        applyHistoryStep(step, redo: false)
        redoSteps.append(step)
    }

    func performRedo() {
        guard let step = redoSteps.popLast() else { return }
        applyHistoryStep(step, redo: true)
        undoSteps.append(step)
    }

    private func applyHistoryStep(_ step: HistoryStep, redo: Bool) {
        switch step {
        case .ink(let before, let after):
            restoreDrawing(redo ? after : before)
        case .journal:
            let before = store.page
            if redo { store.redo() } else { store.undo() }
            refresh(before)
        case .compound(let inkBefore, let inkAfter, let hasObjects):
            if hasObjects {
                let before = store.page
                if redo { store.redo() } else { store.undo() }
                refresh(before)
            }
            if let d = redo ? inkAfter : inkBefore { restoreDrawing(d) }
        }
    }

    /// Record one user action onto the back stack; a new action drops the forward stack (forks history).
    private func recordStep(_ step: HistoryStep, onPage page: UUID? = nil) {
        let targetPage = page ?? store.pageID
        if targetPage == store.pageID {
            undoSteps.append(step)
            if undoSteps.count > maxHistory { undoSteps.removeFirst() }
            redoSteps.removeAll()
            return
        }

        // An async result may finish after navigation. Keep its unified history with the page it actually
        // mutated, so returning there exposes the matching undo step instead of corrupting the visible page.
        var state: PageState
        if let saved = savedPages[targetPage] {
            state = saved
        } else {
            let ink = loadedInk(targetPage)
            state = PageState(ink: ink, undo: [], redo: [], last: ink, consumed: ink.strokes.count)
        }
        state.undo.append(step)
        if state.undo.count > maxHistory { state.undo.removeFirst() }
        state.redo.removeAll()
        savedPages[targetPage] = state
    }

    /// Set the canvas drawing ourselves (undo/redo) WITHOUT the change being recorded as a new step.
    private func restoreDrawing(_ drawing: PKDrawing) {
        setCanvasDrawing(drawing)
        lastDrawing = drawing
        consumedStrokeCount = min(consumedStrokeCount, drawing.strokes.count)   // keep auto-scan in sync
    }

    /// Assign `canvasView.drawing` programmatically (undo/redo, shape-snap, page load, ink restore)
    /// ROBUSTLY. Fixes "undo something, re-draw at the same spot, and the undone ink reappears."
    ///
    /// Root cause: PencilKit commits a `drawing` assignment through its async render/compositing pipeline
    /// (Apple devforums 702903 / 719944). For a window the canvas's live stroke base is still the PRE-swap
    /// drawing, so the user's next stroke gets composited onto it — re-introducing the stroke we just
    /// removed. Tuning the re-enable delay can't close this reliably (the window isn't a fixed duration;
    /// it can persist until the next stroke). So instead we make resurrection *structurally impossible*:
    /// we remember the content-signature of every stroke a swap REMOVES, and the delegate strips any that
    /// reappear (see `canvasViewDrawingDidChange`).
    ///  • `removedStrokeSignatures` is maintained here: strokes leaving the authoritative drawing are
    ///    guarded; strokes (re)appearing — a redo, or undo of a delete — are cleared from the guard, so a
    ///    legitimately-restored stroke is never mistaken for a resurrected one.
    ///  • We still clear PencilKit's own `UndoManager` (a `drawing` swap doesn't reconcile it — devforums
    ///    651788) and briefly disable the drawing gesture to cancel any in-flight stroke.
    ///  • `isRestoringDrawing` stays true across the swap so the delegate never records it as a user edit.
    private func setCanvasDrawing(_ drawing: PKDrawing) {
        // Maintain the resurrection guard against the AUTHORITATIVE pre-swap drawing (`lastDrawing`), which
        // callers update only AFTER this returns — so it still reflects what the canvas held.
        let oldSigs = Set(lastDrawing.strokes.map(Self.strokeSignature))
        let newSigs = Set(drawing.strokes.map(Self.strokeSignature))
        removedStrokeSignatures.formUnion(oldSigs.subtracting(newSigs))   // newly removed → guard them
        removedStrokeSignatures.subtract(newSigs)                          // present again → no longer "removed"

        isRestoringDrawing = true
        canvasView.drawingGestureRecognizer.isEnabled = false
        canvasView.drawing = drawing
        canvasView.undoManager?.removeAllActions()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.canvasView.drawingGestureRecognizer.isEnabled = (self.currentTool != .lasso)
            self.isRestoringDrawing = false
        }
    }

    /// Content-signature of a single stroke, so a stroke PencilKit re-introduces via a stale render can be
    /// recognised and dropped regardless of its index. Hashes the stroke's actual geometry (every control
    /// point's location/timing/pressure/tilt), transform, and ink — NOT `dataRepresentation()`, which is
    /// NOT byte-deterministic for identical content (verified: two serializations of the same stroke
    /// differ), so it cannot be used as an identity. `Hasher` is process-stable, which is all we need: the
    /// signature is captured (on removal) and checked (on a reappearance) within the same process. A
    /// collision with a freshly drawn stroke is ~2⁻⁶⁴ and the guard is armed only briefly after a swap, so
    /// a genuine redraw is never mistaken for a resurrected stroke.
    nonisolated static func strokeSignature(_ stroke: PKStroke) -> Int {
        var h = Hasher()
        h.combine(stroke.ink.inkType)
        if let comps = stroke.ink.color.cgColor.components { for c in comps { h.combine(c) } }
        let t = stroke.transform
        for v in [t.a, t.b, t.c, t.d, t.tx, t.ty] { h.combine(v) }
        for p in stroke.path {
            h.combine(p.location.x); h.combine(p.location.y); h.combine(p.timeOffset)
            h.combine(p.size.width); h.combine(p.size.height)
            h.combine(p.opacity); h.combine(p.force); h.combine(p.azimuth); h.combine(p.altitude)
        }
        return h.finalize()
    }

    /// `PKDrawing.dataRepresentation()` is not byte-stable for identical content, so compare the ordered
    /// deterministic content signatures instead. This prevents phantom history/save/OCR work on a delayed
    /// PencilKit echo that contains exactly the authoritative strokes.
    nonisolated static func drawingsHaveSameContent(_ a: PKDrawing, _ b: PKDrawing) -> Bool {
        guard a.strokes.count == b.strokes.count else { return false }
        return zip(a.strokes, b.strokes).allSatisfy { pair in
            strokeSignature(pair.0) == strokeSignature(pair.1)
        }
    }

    /// Pure stale-render reconciliation: drop any live stroke whose signature is in `removed`, but ONLY
    /// when the drawing has grown past `baselineCount`. A resurrection ADDS strokes, so a same-count or
    /// shrinking change (e.g. a bitmap eraser splitting/removing strokes — its fragments carry NEW
    /// signatures and the count can even rise, but those never match a removed signature) is left
    /// untouched. Returns the kept strokes and whether anything was stripped. Factored out so the
    /// adversarial cases are unit-tested directly (see `InkLabTests`).
    nonisolated static func strippingResurrectedStrokes(_ live: [PKStroke], baselineCount: Int,
                                                        removed: Set<Int>) -> (kept: [PKStroke], stripped: Bool) {
        guard !removed.isEmpty, live.count > baselineCount else { return (live, false) }
        let kept = live.filter { !removed.contains(strokeSignature($0)) }
        return kept.count == live.count ? (live, false) : (kept, true)
    }

    /// Re-write the canvas with a drawing WE corrected (stale-render fix), WITHOUT recording a step and
    /// WITHOUT toggling the drawing gesture (the correction happens between strokes, so it must not cancel
    /// input). `isRestoringDrawing` suppresses the immediate echo; any deferred echo settles harmlessly
    /// against `lastDrawing` via the no-op guard.
    private func reassertDrawing(_ drawing: PKDrawing) {
        isRestoringDrawing = true
        canvasView.drawing = drawing
        canvasView.undoManager?.removeAllActions()
        DispatchQueue.main.async { [weak self] in self?.isRestoringDrawing = false }
    }

    /// Perform a journal transaction AND record it as one back/forward step (so objects interleave with
    /// ink in real creation order). All object mutations route through here. `onPage` lets an async result
    /// (make-real, check, recognize) commit to the page it was STARTED on, even if the user has since
    /// navigated away — the visible overlay only changes when the target IS the visible page.
    private func commitJournal(_ payloads: [OpPayload], onPage page: UUID? = nil) {
        let targetPage = page ?? store.currentPageID
        let visibleBefore = store.page                       // current page projection, for the overlay diff
        store.perform(payloads, onPage: targetPage)
        refresh(visibleBefore)                               // no-op for the visible page if the op targeted another page
        recordStep(.journal, onPage: targetPage)
    }

    // MARK: - Pages (two-finger horizontal swipe: left = next/new, right = previous)

    @objc private func handlePageSwipe(_ g: UISwipeGestureRecognizer) {
        if g.direction == .left { goToNextPage() } else if g.direction == .right { goToPreviousPage() }
    }

    /// Next page — creating a fresh one if we're already at the last page.
    func goToNextPage() {
        let idx = store.currentPageIndex
        if idx + 1 < store.pageCount { switchToPage(store.pageIDs[idx + 1]) }
        else { let id = store.addPage(); switchToPage(id); onStatus?("New page") }
    }

    func goToPreviousPage() {
        let idx = store.currentPageIndex
        if idx > 0 { switchToPage(store.pageIDs[idx - 1]) } else { onStatus?("First page") }
    }

    /// Save the current page's ink + history, swap to `id`, and load its ink + objects + reset scroll.
    private func switchToPage(_ id: UUID) {
        guard id != store.pageID else { return }
        // Persist the outgoing page's ink now (cancel the debounce so it can't fire after the switch).
        pendingInkSave?.cancel()
        // Also cancel any pending auto-@ scan scheduled for the outgoing page so it can't OCR/run against
        // the new page (an already-in-flight scan is separately page-guarded in autoScanForCommand).
        pendingAutoScan?.cancel(); pendingAutoScan = nil
        saveInkData(canvasView.drawing.dataRepresentation(), page: store.pageID)
        savedPages[store.pageID] = PageState(ink: canvasView.drawing, undo: undoSteps, redo: redoSteps,
                                             last: lastDrawing, consumed: consumedStrokeCount)
        let oldPage = store.page
        store.goTo(id)
        // An in-flight "Designing…" card belongs to the page its widget will land on, not the overlay.
        for case let placeholder as DesigningPlaceholderView in overlay.subviews {
            placeholder.isHidden = placeholder.pageID != id
        }
        // Incoming page: its in-session state if we've visited it, else its persisted ink from disk.
        let s: PageState
        if let cached = savedPages[id] {
            s = cached
        } else {
            let ink = loadedInk(id)
            s = PageState(ink: ink, undo: [], redo: [], last: ink, consumed: ink.strokes.count)
        }
        setCanvasDrawing(s.ink)
        undoSteps = s.undo; redoSteps = s.redo; lastDrawing = s.last; consumedStrokeCount = s.consumed
        overlay.apply(projectionDiff(old: oldPage, new: store.page), page: store.page)   // remove old objs, add new
        closeTutorWriteZone()
        canvasView.setContentOffset(.zero, animated: false)
        clearLassoSelection()
        notifyPageChanged()
    }

    private func notifyPageChanged() { onPageChanged?(store.currentPageIndex + 1, store.pageCount) }

    func addSticky() {
        insertObject(kind: .sticky, payload: .sticky(text: "Sticky", colorHex: "#F9DC8C"), size: CGSize(width: 160, height: 120))
    }

    /// Insert a deterministic-engine result as a callout object on the page (`onPage`: the page the
    /// triggering action was started on, for async results that resolve after a page switch).
    func insertResult(_ text: String, onPage page: UUID? = nil) {
        let lines = max(1, text.split(separator: "\n").count)
        insertObject(kind: .callout, payload: .callout(text: text, sourceObjectIDs: [], provenanceJSON: "{}"),
                     size: CGSize(width: 300, height: CGFloat(44 + lines * 22)), onPage: page)
        onStatus?("Added result")
    }

    // MARK: - Recognition (on-device Apple Vision)

    /// Rasterize the page's ink, run on-device recognition, and hand the transcription to the SwiftUI
    /// review sheet. No ink leaves the device.
    func recognizeSelectionOrPage() {
        let drawing = canvasView.drawing
        guard !drawing.strokes.isEmpty else {
            onStatus?("Write something to recognize first.")
            return
        }
        // Prefer the lassoed region if one is active and overlaps ink; otherwise read the whole page.
        var region = drawing.bounds
        if let lasso = lastLassoRect {
            let clipped = lasso.intersection(drawing.bounds)
            if !clipped.isNull, clipped.width > 1, clipped.height > 1 { region = clipped }
        }
        region = region.insetBy(dx: -12, dy: -12)
        guard !region.isNull, region.width > 1, region.height > 1,
              let raster = PencilKitAdapters.raster(drawing, region: region) else {
            onStatus?("Nothing to recognize.")
            return
        }
        let input = RecognitionInput(
            strokes: PencilKitAdapters.strokes(drawing),
            raster: raster,
            region: Rect(x: Double(region.minX), y: Double(region.minY),
                         width: Double(region.width), height: Double(region.height)),
            domainHint: .text,   // Vision returns flat text; the user picks the engine in the review sheet
            session: SessionContext(isOnline: false, userKind: .adult, cloudAIConsentGranted: false)
        )
        onStatus?("Reading…")
        overlay.showScan(in: region)
        let originPage = store.pageID    // tag any result to the page the recognize was started on
        startTrackedTask { [weak self] in
            guard let self else { return }
            defer { self.overlay.hideScan() }
            let result = await self.bestRead(input)
            guard !Task.isCancelled, !self.isDismissing else { return }
            let read = (result?.readAs ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if read.isEmpty {
                self.onStatus?("Couldn't read that — try writing larger and clearer.")
            } else if read.hasPrefix("@") {
                // In-canvas "@" ask-marker: handwriting that starts with @ is a command — run it.
                self.onStatus?("")
                self.runInkCommand(read, onPage: originPage)
            } else {
                self.onStatus?("")   // clear the toast before the review sheet appears
                self.onRecognized?(RecognitionDraft(pageID: originPage, text: read,
                                                    confidence: result?.confidence ?? 0, note: result?.note))
            }
        }
    }

    /// Best available reading for an EXPLICIT Recognize tap. Cloud reads messy math + "@" best, but it's
    /// used ONLY when the user has granted AI consent (Policy A / ADR-0002: never a silent send of ink).
    /// Without consent — or if the cloud read is empty — we stay on-device (Apple Vision: free, private).
    private func bestRead(_ input: RecognitionInput) async -> RecognitionResult? {
        if makeRealSession.blockReason == nil {            // consent granted → cloud is opt-in, allowed
            cloudRecognizer.session = makeRealSession      // send the REAL session (server re-checks it)
            if let r = try? await cloudRecognizer.recognize(input) {
                // Claude answered. An empty reading is its deliberate "can't read this confidently" (the
                // server asks for exactly that), so trust it: on-device Vision's guess at the same scrawl is
                // worse, and would start a tutor session (or run a command) on junk. Vision is the fallback
                // only when the cloud read fails (offline, server error) or isn't allowed.
                return r.readAs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : r
            }
        }
        guard !Task.isCancelled else { return nil }
        return try? await recognizer.recognize(input)
    }

    /// Explicit, on-demand "check my working": read the lassoed region (or the page) ON-DEVICE and run
    /// the deterministic red-pen tutor. This is the ONLY place math help fires — the user asks for it by
    /// tapping Check; it never runs automatically on what they write, and never calls the cloud.
    func checkWork() {
        let drawing = canvasView.drawing
        guard !drawing.strokes.isEmpty else { onStatus?("Write some working first, then tap Check."); return }
        var region = drawing.bounds
        if let lasso = lastLassoRect {
            let clipped = lasso.intersection(drawing.bounds)
            if !clipped.isNull, clipped.width > 1, clipped.height > 1 { region = clipped }
        }
        region = region.insetBy(dx: -12, dy: -12)
        guard !region.isNull, region.width > 1, region.height > 1,
              let raster = PencilKitAdapters.raster(drawing, region: region) else {
            onStatus?("Nothing to check."); return
        }
        let input = RecognitionInput(
            strokes: PencilKitAdapters.strokes(drawing), raster: raster,
            region: Rect(x: Double(region.minX), y: Double(region.minY), width: Double(region.width), height: Double(region.height)),
            domainHint: .math,
            session: SessionContext(isOnline: false, userKind: .adult, cloudAIConsentGranted: false))
        onStatus?("Checking…")
        overlay.showScan(in: region)
        let originPage = store.pageID    // tag the verdict to the page being checked
        startTrackedTask { [weak self] in
            guard let self else { return }
            defer { self.overlay.hideScan() }
            // Best available read: Claude vision when AI-consent is on (reads handwritten math + line
            // breaks far better than on-device Vision), else Apple Vision. The TUTOR ITSELF is the
            // deterministic InkLabMath red-pen — correct-or-silent — only the *reading* uses the cloud.
            let read = (await self.bestRead(input))?.readAs.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !Task.isCancelled, !self.isDismissing else { return }
            guard !read.isEmpty else { self.onStatus?("Couldn't read your working — try writing larger and clearer."); return }
            self.onStatus?("")
            self.insertResult(redPen(read), onPage: originPage)
        }
    }

    // MARK: - Tutor (Socratic hints on the student's own working — see Tutor.swift)

    /// Read the lassoed problem + working (or the page), run the red pen on it, and put the tutor's first
    /// hint next to it. The verdict is the engine's; the tutor only talks about it.
    func startTutor() {
        // The tutor talks through the proxy, so it needs the AI permission up front (the server re-checks).
        if let reason = makeRealSession.tutorBlockReason { onStatus?(reason); return }
        let drawing = canvasView.drawing
        guard !drawing.strokes.isEmpty else { onStatus?("Write a problem and your working, lasso it, then tap Tutor."); return }
        var region = drawing.bounds
        if let lasso = lastLassoRect {
            let clipped = lasso.intersection(drawing.bounds)
            if !clipped.isNull, clipped.width > 1, clipped.height > 1 { region = clipped }
        }
        region = region.insetBy(dx: -12, dy: -12)
        guard !region.isNull, region.width > 1, region.height > 1,
              let raster = PencilKitAdapters.raster(drawing, region: region) else { onStatus?("Nothing to read."); return }
        let input = RecognitionInput(
            strokes: PencilKitAdapters.strokes(drawing), raster: raster,
            region: Rect(x: Double(region.minX), y: Double(region.minY), width: Double(region.width), height: Double(region.height)),
            domainHint: .math,
            session: SessionContext(isOnline: false, userKind: .adult, cloudAIConsentGranted: false))
        // Where each line of the working is on the page (the note points at one of them).
        let strokeBounds = drawing.strokes.map(\.renderBounds)
        // The problem's own ink is not a reply: never let a pending auto-scan read it back to the tutor.
        pendingAutoScan?.cancel(); pendingAutoScan = nil
        consumedStrokeCount = drawing.strokes.count
        clearLassoSelection()
        onStatus?("Reading your working…")
        overlay.showScan(in: region)
        let originPage = store.pageID
        startTrackedTask { [weak self] in
            guard let self else { return }
            let read = (await self.bestRead(input))?.readAs.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.overlay.hideScan()
            guard !Task.isCancelled, !self.isDismissing else { return }
            // A note already saying it couldn't read this problem is picked up again, not duplicated.
            let unread = TutorLayout.sessions(on: self.store.pageProjection(originPage)).map(\.latest.provenance.tutor)
                .first { $0.isUnread && $0.problem.intersects(region) }
            switch TutorSession.start(read: read, problem: region, strokes: strokeBounds) {
            case .failure(.nothingRead):
                // Not a vanishing toast: a note at the problem that stays until they rewrite or type it.
                if unread == nil { self.putTutorNote(.unread(problem: region), text: TutorSession.unreadMessage, page: originPage) }
                self.onStatus?("")
            case .failure(let error): self.onStatus?(error.message)
            case .success(var session):
                if let unread { session.id = unread.id }
                guard !self.tutorBusy.contains(session.id) else { return }
                self.tutorBusy.insert(session.id)
                await self.requestTutorMessage(session, page: originPage)
            }
        }
    }

    /// New ink near a tutor session was written after a pause: read it (consent-gated, like any read)
    /// and send it as the student's reply. An "@" command written there still runs as a command.
    private func readTutorReply(_ input: RecognitionInput, sessionID: UUID, firedCount: Int, page: UUID) {
        autoScanBusy = true
        startTrackedTask { [weak self] in
            guard let self else { return }
            defer {
                self.autoScanBusy = false
                if self.autoScanNeedsRetry { self.autoScanNeedsRetry = false; self.scheduleAutoScan() }
            }
            let read = (await self.bestRead(input))?.readAs.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !Task.isCancelled, !self.isDismissing, self.store.pageID == page else { return }
            self.consumedStrokeCount = firedCount   // examined — never re-read (the ink stays on the page)
            guard !read.isEmpty else { self.onStatus?("Couldn't read your reply — try writing a little larger."); return }
            if read.hasPrefix("@") { self.runInkCommand(read, onPage: page); return }
            if self.tutorWriteZone?.session == sessionID { self.closeTutorWriteZone() }
            self.sendTutorReply(sessionID: sessionID, text: read, wantsHint: false, page: page)
        }
    }

    /// Sent from a tutor note's drop-down box: a typed reply (or a request for the next hint), or the
    /// problem typed as it really is — the session starts over from that, unless nothing changed.
    private func tutorTyped(_ typed: TutorTypedReply, calloutID: UUID) {
        guard let session = tutorSession(of: calloutID) else { return }
        let page = store.pageID
        switch typed {
        case .reply(let text, let wantsHint):
            sendTutorReply(sessionID: session.id, text: text, wantsHint: wantsHint, page: page)
        case .reading(let text):
            guard TutorSession.steps(from: text) != session.pageLines else { return }
            restartTutor(session, read: text, page: page)
        }
    }

    /// "Write on the page": highlight a free space under the problem and read the next ink written there
    /// as the student's reply (ink elsewhere near the problem still counts, as before).
    private func openTutorWriteZone(calloutID: UUID) {
        guard let obj = store.page.objects[calloutID], case .callout(_, _, let json) = obj.payload,
              let provenance = TutorCalloutProvenance.decode(json) else { return }
        closeTutorWriteZone()
        let session = provenance.tutor
        let avoid = TutorLayout.obstacles(ink: canvasView.drawing.strokes.map(\.renderBounds), page: store.page, except: nil)
        let rect = TutorLayout.writeZone(problem: session.problem, avoiding: avoid, canvasWidth: view.bounds.width)
        let zoneView = TutorWriteZoneView(frame: rect, caption: session.isUnread ? TutorWriteZoneView.rewriteCaption : TutorWriteZoneView.replyCaption)
        zoneView.onCancel = { [weak self] in self?.closeTutorWriteZone() }
        overlay.addSubview(zoneView)
        tutorWriteZone = (session: session.id, page: store.pageID, rect: rect, view: zoneView)
        // Writing needs a drawing tool, and ink already on the page is not the reply.
        if currentTool != .pen && currentTool != .highlighter { onSelectTool?(.pen) }
        pendingAutoScan?.cancel(); pendingAutoScan = nil
        consumedStrokeCount = canvasView.drawing.strokes.count
        canvasView.scrollRectToVisible(rect.insetBy(dx: -24, dy: -24), animated: true)
        onStatus?(session.isUnread ? "Write the problem again in the highlighted space — \(TutorSession.tutorName) reads it when you pause."
                                   : "Write your reply in the highlighted space — \(TutorSession.tutorName) reads it when you pause.")
    }

    /// The tutor session a note belongs to (its state rides in the note's provenance).
    private func tutorSession(of calloutID: UUID) -> TutorSession? {
        guard let obj = store.page.objects[calloutID], case .callout(_, _, let json) = obj.payload else { return nil }
        return TutorCalloutProvenance.decode(json)?.tutor
    }

    /// Start `old`'s conversation over on a new reading (typed, corrected or re-read): same note, fresh
    /// verdict, hint 1. A reading that is still empty leaves the note as it is.
    private func restartTutor(_ old: TutorSession, read: String, problem: CGRect? = nil, page: UUID) {
        if let reason = makeRealSession.tutorBlockReason { onStatus?(reason); return }
        let ink = (page == store.pageID ? canvasView.drawing : loadedInk(page)).strokes.map(\.renderBounds)
        switch old.restarted(read: read, problem: problem, strokes: ink) {
        case .failure(.nothingRead):
            onStatus?("Still couldn't read it — try writing a little larger, or tap Type it.")
        case .failure(let error):
            onStatus?(error.message)
        case .success(let fresh):
            guard !tutorBusy.contains(fresh.id) else { onStatus?("\(TutorSession.tutorName) is still answering — try again in a moment."); return }
            pendingTutorReplies[fresh.id] = nil          // replies to the old reading don't apply any more
            tutorBusy.insert(fresh.id)
            startTrackedTask { [weak self] in await self?.requestTutorMessage(fresh, page: page) }
        }
    }

    /// New ink by a note that couldn't read its problem: read the problem again, the new ink on its own if
    /// it was written beside the old (a fresh copy), or together with it if written over it (a touch-up).
    private func rereadTutorProblem(_ session: TutorSession, newInk: CGRect, firedCount: Int, page: UUID) {
        let drawing = canvasView.drawing
        let region = (newInk.intersects(session.problem) ? session.problem.union(newInk) : newInk).insetBy(dx: -12, dy: -12)
        guard !region.isNull, region.width > 1, region.height > 1,
              let raster = PencilKitAdapters.raster(drawing, region: region) else { consumedStrokeCount = firedCount; return }
        let input = RecognitionInput(
            strokes: PencilKitAdapters.strokes(drawing), raster: raster,
            region: Rect(x: Double(region.minX), y: Double(region.minY), width: Double(region.width), height: Double(region.height)),
            domainHint: .math,
            session: SessionContext(isOnline: false, userKind: .adult, cloudAIConsentGranted: false))
        autoScanBusy = true
        onStatus?("Reading your working…")
        overlay.showScan(in: region)
        startTrackedTask { [weak self] in
            guard let self else { return }
            defer {
                self.autoScanBusy = false
                if self.autoScanNeedsRetry { self.autoScanNeedsRetry = false; self.scheduleAutoScan() }
            }
            let read = (await self.bestRead(input))?.readAs.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.overlay.hideScan()
            guard !Task.isCancelled, !self.isDismissing, self.store.pageID == page else { return }
            self.consumedStrokeCount = firedCount
            if self.tutorWriteZone?.session == session.id, !read.isEmpty { self.closeTutorWriteZone() }
            self.restartTutor(session, read: read, problem: region, page: page)
        }
    }

    private func closeTutorWriteZone() {
        tutorWriteZone?.view.removeFromSuperview()
        tutorWriteZone = nil
    }

    /// Add the student's reply (the engine checks any math in it) and ask for the next tutor message.
    private func sendTutorReply(sessionID: UUID, text: String, wantsHint: Bool, page: UUID) {
        if let reason = makeRealSession.tutorBlockReason { onStatus?(reason); return }
        guard !tutorBusy.contains(sessionID) else {
            pendingTutorReplies[sessionID, default: []].append((text: text, wantsHint: wantsHint, page: page))
            onStatus?("\(TutorSession.tutorName) is still answering — your reply is next.")
            return
        }
        guard let current = TutorLayout.sessions(on: store.pageProjection(page))
            .first(where: { $0.latest.provenance.tutor.id == sessionID })?.latest.provenance.tutor else {
            onStatus?("That tutor conversation was removed.")
            return
        }
        guard !current.isUnread else { return }   // nothing was read yet: rewriting or typing it starts the session
        guard current.thread.count < TutorSession.maxThread else {
            onStatus?("This conversation is getting long — lasso the problem and tap Tutor to start fresh.")
            return
        }
        let next = current.addingStudentReply(text, wantsHint: wantsHint)
        tutorBusy.insert(sessionID)
        startTrackedTask { [weak self] in
            await self?.requestTutorMessage(next, page: page)
        }
    }

    /// Ask for the next tutor message on `session` (its thread already ends with the student's turn, if
    /// any) and journal it into the session's margin note — one undoable step per message.
    private func requestTutorMessage(_ session: TutorSession, page: UUID) async {
        defer {
            tutorBusy.remove(session.id)
            drainTutorReplies(session.id)
        }
        onStatus?("\(TutorSession.tutorName) is thinking…")
        do {
            let reply = try await Tutor.nextMessage(for: session, consent: makeRealSession)
            guard !Task.isCancelled, !isDismissing else { return }
            var next = session
            next.rung = reply.rung
            next.thread.append(TutorTurn(role: .tutor, text: reply.reply))
            putTutorNote(next, text: reply.reply, page: page)
            onStatus?("")
        } catch {
            guard !Task.isCancelled, !isDismissing else { return }
            onStatus?(error.localizedDescription)
        }
    }

    private func drainTutorReplies(_ sessionID: UUID) {
        guard !isDismissing, var queue = pendingTutorReplies[sessionID], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        pendingTutorReplies[sessionID] = queue.isEmpty ? nil : queue
        sendTutorReply(sessionID: sessionID, text: next.text, wantsHint: next.wantsHint, page: next.page)
    }

    /// The session's margin note: inserted beside the line the verdict is about on the first message, then
    /// updated in place (payload replaced + re-sized, one journal transaction = one undo step) for each
    /// message after. It stays where the student moved it unless the taller note would now cover ink or
    /// another object; it never covers either, and it is drawn above every other object.
    private func putTutorNote(_ session: TutorSession, text: String, page: UUID) {
        let pageObjects = store.pageProjection(page)
        let existing = TutorLayout.sessions(on: pageObjects).first { $0.latest.provenance.tutor.id == session.id }?.latest
        let provenance = TutorCalloutProvenance(tutor: session, turn: (existing?.provenance.turn ?? 0) + 1)
        let payload = ObjectPayload.callout(text: text, sourceObjectIDs: [], provenanceJSON: provenance.json)
        let width = TutorNoteStyle.current.width
        let size = CGSize(width: width, height: TutorNoteView.height(for: provenance, width: width))
        let ink = (page == store.pageID ? canvasView.drawing : loadedInk(page)).strokes.map(\.renderBounds)
        let avoid = TutorLayout.obstacles(ink: ink, page: pageObjects, except: existing?.objectID)
        let placed = TutorLayout.marginFrame(size: size, anchor: session.anchorRect, problem: session.problem,
                                             avoiding: avoid, canvasWidth: view.bounds.width)
        let frame: CGRect
        if let existing, let obj = pageObjects.objects[existing.objectID] {
            let kept = CGRect(origin: existing.frame.origin, size: size)
            // A problem rewritten somewhere else moves its note with it.
            let problemMoved = existing.provenance.tutor.problem != session.problem
            frame = problemMoved || avoid.contains(where: { $0.insetBy(dx: -8, dy: -8).intersects(kept) }) ? placed : kept
            var ops: [OpPayload] = [.promote(objectID: obj.objectID, old: obj.payload, new: payload)]
            let moved = Transform(x: Double(frame.minX), y: Double(frame.minY), width: Double(frame.width),
                                  height: Double(frame.height), rotation: obj.transform.rotation)
            if moved != obj.transform { ops.append(.setTransform(objectID: obj.objectID, old: obj.transform, new: moved)) }
            commitJournal(ops, onPage: page)
        } else {
            frame = placed
            insertObject(kind: .callout, payload: payload, size: size, aiProvenance: provenance.json,
                         at: CGPoint(x: frame.midX, y: frame.midY), onPage: page, z: TutorLayout.topZ(on: pageObjects))
        }
        if page == store.pageID {
            canvasView.scrollRectToVisible(frame.insetBy(dx: 0, dy: -24), animated: true)
        }
    }

    // MARK: - Fit a sketched curve → a live, correct graph (InkLabFit, on-device, deterministic)

    /// "Bring a hand-drawn graph to life": sample the lassoed sketch (or the whole page's ink), run
    /// InkLabFit's exact least-squares, and drop a native best-fit graph (model type + equation + R²).
    /// Pure geometry + deterministic math — no OCR, no cloud.
    func fitLassoedSketch() {
        let rect = lastLassoRect
        var pts: [Point2D] = []
        for stroke in canvasView.drawing.strokes {
            if let rect, !stroke.renderBounds.intersects(rect) { continue }
            for p in stroke.path {
                let loc = p.location.applying(stroke.transform)   // true rendered coords (handles moved strokes)
                if let rect, !rect.contains(loc) { continue }
                pts.append(Point2D(x: Double(loc.x), y: Double(-loc.y)))   // flip y: screen-down → math-up
            }
        }
        guard pts.count >= 4 else { onStatus?("Sketch a curve, lasso it, then tap Fit (the graph icon)."); return }
        guard let state = CurveFitter.fit(pts) else { onStatus?("Couldn't fit a curve to that — try a clearer left-to-right sketch."); return }
        guard let data = try? JSONEncoder().encode(state), let json = String(data: data, encoding: .utf8) else { return }
        insertObject(kind: .widget,
                     payload: .widget(html: BlobRef(id: UUID(), kind: .widgetBundle, byteCount: json.utf8.count),
                                      jsState: json, sandboxPolicy: "native:fitGraph"),
                     size: NativeWidgetRegistry.defaultSize(kind: "fitGraph"))
        clearLassoSelection()
        onStatus?("Fit: \(state.model) (R² = \(String(format: "%.2f", state.rSquared)))")
    }

    // MARK: - Handwrite → plot (recognize writing drawn on a widget, feed it to the widget's input)

    /// Recognize the handwriting drawn over a widget and feed the result into the widget (e.g. plot a
    /// handwritten function on a graph). Uses the same consent-gated recognizer as the Recognize button.
    private func recognizeAnnotationAndDrive(_ id: UUID, _ image: UIImage) {
        guard let png = image.pngData() else { return }
        let scale = image.scale
        let input = RecognitionInput(
            strokes: [],
            raster: RasterImage(pngData: png, width: Int(image.size.width * scale), height: Int(image.size.height * scale)),
            region: Rect(x: 0, y: 0, width: Double(image.size.width), height: Double(image.size.height)),
            domainHint: .math,
            session: SessionContext(isOnline: false, userKind: .adult, cloudAIConsentGranted: false))
        onStatus?("Reading your writing…")
        startTrackedTask { [weak self] in
            guard let self else { return }
            let read = (await self.bestRead(input))?.readAs.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !Task.isCancelled, !self.isDismissing else { return }
            guard !read.isEmpty else { self.onStatus?("Couldn't read that — write the formula larger and clearer."); return }
            let expr = Self.plottableExpression(read)
            self.overlay.setWidgetInput(id, expr)
            self.onStatus?("Sent “\(expr)” to the widget")
        }
    }

    /// Trim a recognized "y = …" / "f(x) = …" down to the bare expression a grapher wants.
    static func plottableExpression(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = t.lowercased().replacingOccurrences(of: " ", with: "")
        if compact.hasPrefix("y=") || compact.hasPrefix("f(x)=") || compact.hasPrefix("ƒ(x)="),
           let eq = t.firstIndex(of: "=") {
            return String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        // Ignore changes WE made during undo/redo, a reassert correction, or a live lasso move — those
        // aren't new user strokes (a move records its own combined step on release and must not clear the
        // active selection).
        if isRestoringDrawing || movingSelection { return }

        // Stale-render defense — the "undo, rewrite on the same spot, undone ink returns" bug. PencilKit
        // can composite a new stroke onto a drawing it hasn't finished swapping, re-introducing strokes a
        // programmatic undo/redo/snap just removed. We tracked those strokes' exact signatures; strip any
        // that reappear. This runs ONLY while the guard is armed (i.e. just after a swap) AND the live
        // drawing has grown (a resurrection adds strokes) — so the steady-state path stays as cheap as
        // before, and a legitimate eraser split (which also grows the count, but with NEW signatures) is
        // never touched.
        let live = canvasView.drawing
        let (strokes, stripped) = Self.strippingResurrectedStrokes(
            live.strokes, baselineCount: lastDrawing.strokes.count, removed: removedStrokeSignatures)
        let authoritative = stripped ? PKDrawing(strokes: strokes) : live

        // No-op: the canvas (after any stripping) already equals our known baseline — a settled
        // programmatic echo, or a stale echo we just stripped back to baseline. Correct the display if it
        // was showing resurrected ink, but record nothing. The expensive byte-compare only runs when
        // stroke counts match (rare for a real edit, which changes the count).
        if authoritative.strokes.count == lastDrawing.strokes.count,
           Self.drawingsHaveSameContent(authoritative, lastDrawing) {
            if stripped { reassertDrawing(authoritative) }
            return
        }

        // A genuine user edit (possibly after stripping a resurrected stroke). If we stripped, push the
        // corrected drawing back so screen + model agree, and keep the guard armed (the canvas just proved
        // its base is still stale). A CLEAN edit proves the base settled, so we disarm to keep the fast
        // path fast.
        if stripped { reassertDrawing(authoritative) }
        let addedStroke = authoritative.strokes.count > lastDrawing.strokes.count
        clearLassoSelection()   // new ink invalidates any prior lasso selection
        // Record this handwriting change as ONE back/forward step, interleaved with object ops, so the
        // toolbar undo/redo steps to the exact previous/next thing the user made — ink included.
        recordStep(.ink(before: lastDrawing, after: authoritative))
        lastDrawing = authoritative
        if !stripped { removedStrokeSignatures.removeAll() }
        scheduleInkSave()
        // Draw-and-hold: snap if EITHER the live hold-gesture armed it OR the finished stroke's own
        // trailing samples show the pencil dwelled ≥0.5s. The latter is robust for Apple Pencil (which
        // keeps streaming samples while held) and works even when the live gesture signal doesn't fire. A
        // snapped shape isn't an "@" command, so skip the auto-scan in that case. Skip snapping entirely on
        // a stale-render correction cycle (`stripped`) — the canvas is mid-reassert, not a clean stroke.
        let drawingTool = currentTool == .pen || currentTool == .highlighter
        let dwellHeld = addedStroke && (authoritative.strokes.last.map(strokeEndedWithHold) ?? false)
        let held = snapShapesEnabled && drawingTool && (shapeSnapArmed || dwellHeld)
        shapeSnapArmed = false
        if !stripped, held, addedStroke, snapLastStrokeToShape() { return }
        scheduleAutoScan()
    }

    /// Persist the current page's ink shortly after the user pauses (never-lose-ink across relaunch).
    private func scheduleInkSave() {
        pendingInkSave?.cancel()
        let page = store.pageID
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.enqueueInkData(self.canvasView.drawing.dataRepresentation(), page: page)
        }
        pendingInkSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Load a page's persisted ink (empty drawing if none).
    private func loadedInk(_ page: UUID) -> PKDrawing {
        if let data = loadInkData(page: page) {
            do { return try PKDrawing(data: data) }
            catch { reportPersistenceFailure(error) }
        }
        return PKDrawing()
    }

    private func loadInkData(page: UUID) -> Data? {
        guard store.isPersistenceReadable else {
            if let error = store.loadFailure { reportPersistenceFailure(error) }
            return nil
        }
        do { return try storage.loadInk(page: page) }
        catch { reportPersistenceFailure(error); return nil }
    }

    @discardableResult
    private func saveInkData(_ data: Data, page: UUID) -> Bool {
        guard store.isPersistenceAvailable else {
            if let error = store.persistenceFailure { reportPersistenceFailure(error) }
            return false
        }
        do { try storage.saveInk(data, page: page); return true }
        catch { reportPersistenceFailure(error); return false }
    }

    private func enqueueInkData(_ data: Data, page: UUID) {
        guard store.isPersistenceAvailable else {
            if let error = store.persistenceFailure { reportPersistenceFailure(error) }
            return
        }
        storage.saveInkAsync(data, page: page) { [weak self] error in
            if let error { self?.reportPersistenceFailure(error) }
        }
    }

    private func reportPersistenceFailure(_ error: Error) {
        let detail = error.localizedDescription
        onPersistenceWarning?("Not saved — keep this notebook open and export/retry before leaving. \(detail)")
    }

    /// Debounce: after the user pauses (~1.2s with no new strokes), scan the new ink for an "@" command.
    private func scheduleAutoScan() {
        guard autoCommandsEnabled || !TutorLayout.sessions(on: store.page).isEmpty else { return }
        pendingAutoScan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autoScanForCommand() }
        pendingAutoScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)   // wait until they've paused
    }

    /// OCR only the strokes added since we last looked. If they read as "@…", run it and erase that ink.
    private func autoScanForCommand() {
        let tutorSessions = TutorLayout.sessions(on: store.page)
        guard autoCommandsEnabled || !tutorSessions.isEmpty else { return }
        guard !autoScanBusy else { autoScanNeedsRetry = true; return }
        let strokes = canvasView.drawing.strokes
        consumedStrokeCount = min(consumedStrokeCount, strokes.count)   // resync if ink was erased
        guard strokes.count > consumedStrokeCount else { return }
        let newStrokes = Array(strokes[consumedStrokeCount..<strokes.count])
        // Skip very large batches (long-form notes); a page with several "@" commands can still be many
        // strokes, so the cap is generous — we want to catch every command, not just the first one or two.
        guard newStrokes.count <= 200 else { consumedStrokeCount = strokes.count; return }

        let batch = PKDrawing(strokes: newStrokes)
        let region = batch.bounds.insetBy(dx: -12, dy: -12)
        guard !region.isNull, region.width > 1, region.height > 1,
              let raster = PencilKitAdapters.raster(batch, region: region) else {
            consumedStrokeCount = strokes.count
            return
        }
        let input = RecognitionInput(
            strokes: PencilKitAdapters.strokes(batch), raster: raster,
            region: Rect(x: Double(region.minX), y: Double(region.minY), width: Double(region.width), height: Double(region.height)),
            domainHint: .text,
            session: SessionContext(isOnline: false, userKind: .adult, cloudAIConsentGranted: false)
        )
        let firedCount = strokes.count
        let scanPage = store.pageID            // the page these strokes belong to
        // Ink in the highlighted write-here space is that session's reply; otherwise new ink next to a
        // session's problem (or its note) is. By a note that couldn't read its problem, it's the problem
        // written again.
        let target: TutorSession?
        if let zone = tutorWriteZone, zone.page == scanPage, zone.rect.intersects(batch.bounds) {
            target = tutorSessions.first { $0.latest.provenance.tutor.id == zone.session }?.latest.provenance.tutor
        } else {
            target = tutorSessions.first(where: {
                TutorLayout.replyZone(problem: $0.latest.provenance.tutor.problem, callouts: $0.all.map(\.frame)).intersects(batch.bounds)
            })?.latest.provenance.tutor
        }
        if let target {
            if target.isUnread { rereadTutorProblem(target, newInk: batch.bounds, firedCount: firedCount, page: scanPage) }
            else { readTutorReply(input, sessionID: target.id, firedCount: firedCount, page: scanPage) }
            return
        }
        guard autoCommandsEnabled else { consumedStrokeCount = strokes.count; return }
        autoScanBusy = true
        startTrackedTask { [weak self] in
            guard let self else { return }
            defer {
                self.autoScanBusy = false
                if self.autoScanNeedsRetry {
                    self.autoScanNeedsRetry = false
                    self.scheduleAutoScan()
                }
            }
            // On-device first (free, private). Run EVERY "@" command found — multiple per page works.
            var read = (try? await self.recognizer.recognize(input))?.readAs ?? ""
            guard !Task.isCancelled, !self.isDismissing else { return }
            var commands = Self.extractAtCommands(read)
            // Apple Vision misreads a handwritten "@" (often as "a"). If none were found but the scribble
            // is short and "@-shaped", re-check with the cloud recognizer — but ONLY with AI consent
            // (so ordinary notes never go to the cloud). This is the only cloud call the auto-scan makes.
            if commands.isEmpty, self.makeRealSession.blockReason == nil, Self.looksLikeAtScribble(read) {
                self.cloudRecognizer.session = self.makeRealSession
                if let cloud = try? await self.cloudRecognizer.recognize(input) {
                    read = cloud.readAs
                    commands = Self.extractAtCommands(read)
                }
                guard !Task.isCancelled, !self.isDismissing else { return }
            }
            // The user may have switched pages during recognition. If so, DON'T touch this (now-current)
            // page's consumedStrokeCount or run the command here — the strokes still live on `scanPage`
            // and will be re-scanned (and run exactly once) when the user returns to it.
            guard self.store.pageID == scanPage else { return }
            self.consumedStrokeCount = firedCount   // examined — never re-scan these strokes (keep the ink)
            for command in commands { self.runInkCommand(command, onPage: scanPage) }
        }
    }

    /// Pull EVERY "@…" command out of recognized text. Handles multiple per page/line, e.g.
    /// "@a clock\n@a piano" → ["@a clock", "@a piano"] and "notes @balance H2 @molar C6" → the two
    /// commands. A command runs from each "@" up to the next "@" (or end of line).
    static func extractAtCommands(_ text: String) -> [String] {
        var commands: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            var i = line.startIndex
            while let at = line[i...].firstIndex(of: "@") {
                let after = line.index(after: at)
                let next = line[after...].firstIndex(of: "@") ?? line.endIndex
                let command = line[at..<next].trimmingCharacters(in: .whitespaces)
                if command.count > 1 { commands.append(command) }
                i = next
            }
        }
        return commands
    }

    /// A short on-device read that might be a misread "@" (Apple Vision often reads a handwritten "@"
    /// as a round glyph). Narrow, and used ONLY to decide a consent-gated cloud re-check — not to run.
    private static func looksLikeAtScribble(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 20, let c = t.lowercased().first else { return false }
        return "aoecqg09(".contains(c)
    }

    @discardableResult
    private func insertObject(kind: ObjectKind, payload: ObjectPayload, size: CGSize,
                              aiProvenance: String? = nil, at explicitCenter: CGPoint? = nil,
                              onPage page: UUID? = nil, z: FractionalIndex? = nil) -> UUID {
        let id = UUID()
        let targetPage = page ?? store.pageID
        // Visible center in CONTENT coordinates (the overlay is scrolled with the canvas). When an
        // explicit center is given (drop a generated widget exactly where its placeholder was), use it
        // as-is; otherwise pick the visible center and cascade so repeated inserts don't stack.
        let center: CGPoint
        if let explicitCenter {
            center = explicitCenter
        } else {
            insertOffset = insertOffset >= 120 ? 0 : insertOffset + 24
            // A reviewed async result may target a page that is no longer visible. Never borrow the
            // current page's scroll offset for that background page; page switches reopen at the top.
            let targetOffsetY = targetPage == store.pageID ? canvasView.contentOffset.y : 0
            center = CGPoint(x: view.bounds.midX + insertOffset,
                             y: targetOffsetY + view.bounds.midY + insertOffset)
        }
        let t = Transform(x: Double(center.x - size.width / 2),
                          y: Double(center.y - size.height / 2),
                          width: Double(size.width), height: Double(size.height))
        let snapshot = ObjectSnapshot(objectID: id, kind: kind, transform: t, z: z ?? FractionalIndex("m"),
                                      pageID: targetPage, createdBy: store.notebookID, payload: payload)
        let op: OpPayload = aiProvenance.map { .aiInsert(snapshot: snapshot, provenanceJSON: $0) }
            ?? .addObject(snapshot: snapshot)
        commitJournal([op], onPage: targetPage)
        return id
    }

    // MARK: - Make-real (generate a live widget from a request)

    /// The headline "magic": send any request to the generator (Server → Claude), render the returned
    /// HTML as a live, sandboxed, draggable, undoable object. Needs the Server running + an API key;
    /// otherwise the request fails with a clear reason rather than a fake placeholder.
    func makeReal(prompt: String, onPage page: UUID? = nil) {
        guard !prompt.isEmpty else { return }
        // Gate on consent BEFORE any network call (the server re-checks too — defence in depth).
        if let reason = makeRealSession.blockReason { onStatus?(reason); return }
        // The page this generation belongs to — the finished widget lands here even if the user navigates
        // away during the ~20s generation (otherwise it would be journaled onto whatever page is current
        // at completion).
        let targetPage = page ?? store.pageID
        // One generation at a time (each spawns a WKWebView + a Claude call). Extra "@"s wait their turn.
        guard !isGenerating else {
            makeRealQueue.append((prompt: prompt, pageID: targetPage))
            onStatus?("Queued “\(prompt)”…")
            return
        }
        isGenerating = true
        onStatus?("Designing “\(prompt)”…")
        let session = makeRealSession
        // Show an animated "Designing…" card on the canvas where the widget will land, so the generation
        // reads as work-in-progress rather than a frozen app. It's purely visual (not a journal object) —
        // removed and replaced by the real widget when generation finishes. The card shape is only known
        // once the widget arrives, so the placeholder is the default portrait card.
        let placeholderSize = WidgetCard.size(content: WidgetLayout.portrait.contentSize)
        // A queued job can start after the user moved to another page. That page reopens at the top, so
        // don't borrow the visible page's scroll offset for it (same rule as `insertObject`).
        let offsetY = targetPage == store.pageID ? canvasView.contentOffset.y : 0
        let center = CGPoint(x: view.bounds.midX, y: offsetY + view.bounds.midY)
        let placeholderFrame = CGRect(x: center.x - placeholderSize.width / 2, y: center.y - placeholderSize.height / 2,
                                      width: placeholderSize.width, height: placeholderSize.height)
        let placeholder = DesigningPlaceholderView(prompt: prompt, pageID: targetPage, frame: placeholderFrame)
        placeholder.isHidden = targetPage != store.pageID
        overlay.addSubview(placeholder)
        startTrackedTask { [weak self] in
            guard let self else { return }
            defer { self.isGenerating = false; self.drainMakeRealQueue() }
            do {
                var widget = try await MakeReal.provider.generate(prompt: prompt, session: session)
                guard !Task.isCancelled, !self.isDismissing else { return }
                // Render check: run it hidden first. A widget that crashes or shows nothing is regenerated once,
                // with the error, while the "Designing…" card stays up, so students never see a blank card.
                var health = await WidgetRenderCheck.run(html: widget.html, size: widget.layout.contentSize)
                var warning: String?
                if !health.ok {
                    guard !Task.isCancelled, !self.isDismissing else { return }
                    placeholder.setStatus("Fixing a problem")
                    self.onStatus?("That design didn't work, fixing it…")
                    widget = try await MakeReal.provider.generate(prompt: makeRealRetryPrompt(prompt, after: health), session: session)
                    guard !Task.isCancelled, !self.isDismissing else { return }
                    health = await WidgetRenderCheck.run(html: widget.html, size: widget.layout.contentSize)
                    // Still broken: place it anyway (it may partly work) and say so; the student can delete or retry.
                    if !health.ok { warning = "“\(prompt)” may not work fully. Try describing it differently." }
                }
                guard !Task.isCancelled, !self.isDismissing else { return }
                placeholder.stop(); placeholder.removeFromSuperview()
                let provenance = (try? String(data: JSONSerialization.data(withJSONObject: ["prompt": prompt]), encoding: .utf8)) ?? "{}"
                self.insertObject(kind: .widget,
                                  payload: .widget(html: BlobRef(id: UUID(), kind: .widgetBundle, byteCount: widget.html.utf8.count),
                                                   jsState: widget.html, sandboxPolicy: "sandboxed"),
                                  size: WidgetCard.size(content: widget.layout.contentSize),   // the shape it was designed for
                                  aiProvenance: provenance,
                                  at: center,        // drop it exactly where the placeholder was
                                  onPage: targetPage)   // …on the page the request was started on
                self.onStatus?(warning ?? "Created “\(prompt)”")
            } catch {
                placeholder.stop(); placeholder.removeFromSuperview()
                guard !Task.isCancelled, !self.isDismissing else { return }
                self.onStatus?("Couldn't create that — \(error.localizedDescription)")
            }
        }
    }

    /// Start the next queued make-real, if any (called when one finishes).
    private func drainMakeRealQueue() {
        guard !isDismissing, !isGenerating, !makeRealQueue.isEmpty else { return }
        let job = makeRealQueue.removeFirst()
        makeReal(prompt: job.prompt, onPage: job.pageID)
    }

    /// Run an "@" command written in ink: exact engine for known verbs, else make-real generation.
    /// `onPage` keeps the result on the page the command was written on across an async generation.
    private func runInkCommand(_ raw: String, onPage page: UUID? = nil) {
        if isDeterministicEngineCommand(raw) {
            insertResult(runCommand(raw), onPage: page)
        } else {
            makeReal(prompt: makeRealPrompt(raw), onPage: page)
        }
    }

    /// Drop a native live widget onto the page (Tier A make-real: correct-by-construction, on-device).
    func insertWidget(kind: String) {
        let size = NativeWidgetRegistry.defaultSize(kind: kind)
        let payload = ObjectPayload.widget(html: BlobRef(id: UUID(), kind: .widgetBundle, byteCount: 0),
                                           jsState: NativeWidgetRegistry.initialState(kind: kind),
                                           sandboxPolicy: "native:\(kind)")
        insertObject(kind: .widget, payload: payload, size: size)
        onStatus?("Added \(NativeWidgetRegistry.title(kind: kind))")
    }

    /// Journal a widget's settled state as ONE undo step (no-op guarded).
    private func commitWidgetState(_ id: UUID, _ old: String, _ new: String) {
        guard old != new, store.page.objects[id] != nil else { return }
        commitJournal([.setObjectState(objectID: id, old: old, new: new)])
    }

    /// Commit an edited sticky's text (undoable).
    private func editStickyText(_ id: UUID, _ old: String, _ new: String) {
        guard store.page.objects[id] != nil, old != new else { return }
        commitJournal([.setProps(objectID: id, old: PropPatch(stickyText: old), new: PropPatch(stickyText: new))])
    }

    /// Remove an object (undoable — undo restores it).
    private func deleteObject(_ id: UUID) {
        guard store.page.objects[id] != nil else { return }
        commitJournal([.delete(objectID: id)])
        onStatus?("Deleted — undo (↩) to bring it back")
    }

    private func commitMove(_ id: UUID, _ newTransform: Transform) {
        guard let old = store.page.objects[id] else { return }
        commitJournal([.setTransform(objectID: id, old: old.transform, new: newTransform)])
    }

    private func refresh(_ before: PageProjection) {
        overlay.apply(projectionDiff(old: before, new: store.page), page: store.page)
        // The write-here space belongs to a session: closing (or undoing) the session removes it.
        if let zone = tutorWriteZone, zone.page == store.pageID,
           !TutorLayout.sessions(on: store.page).contains(where: { $0.latest.provenance.tutor.id == zone.session }) {
            closeTutorWriteZone()
        }
    }

    // MARK: - Lasso

    @objc private func handleLasso(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: overlay)
        switch g.state {
        case .began:
            // A single-finger drag that BEGINS inside the current selection MOVES it; otherwise it starts
            // a new loop (which drops the old selection).
            if hasLassoSelection, lastLassoRect?.contains(p) == true {
                beginMove(at: p)
            } else {
                clearLassoSelection()
                lassoPoints = [p]
                liveLassoPath.removeAllPoints()
                liveLassoPath.move(to: p)
            }
        case .changed:
            if movingSelection { updateMove(to: p) } else { appendLassoPoint(p) }
        case .ended:
            if movingSelection { endMove(to: p) } else { finishLasso() }
        default:
            if movingSelection { cancelMove() } else { lassoPoints = []; clearLassoSelection() }
        }
    }

    private func appendLassoPoint(_ point: CGPoint) {
        if let last = lassoPoints.last,
           hypot(point.x - last.x, point.y - last.y) < lassoSampleSpacing { return }
        lassoPoints.append(point)
        liveLassoPath.addLine(to: point)
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // the loop must follow the finger, not ease behind it
        lassoLayer.path = liveLassoPath.cgPath
        CATransaction.commit()
    }

    // MARK: - Draw-and-hold shape snapping

    /// Passive tracker callback. Arms a snap when the pencil is held roughly still for `shapeHoldSeconds`
    /// mid-stroke; the snap itself happens when the stroke completes (canvasViewDrawingDidChange).
    @objc private func handleShapeHold(_ g: UIGestureRecognizer) {
        guard snapShapesEnabled, currentTool == .pen || currentTool == .highlighter else { return }
        let p = g.location(in: canvasView)
        switch g.state {
        case .began:
            lastHoldPoint = p; shapeSnapArmed = false; armHoldTimer()
        case .changed:
            if hypot(p.x - lastHoldPoint.x, p.y - lastHoldPoint.y) > shapeHoldJitter {
                lastHoldPoint = p
                shapeSnapArmed = false        // moved again → not a hold-then-lift; require a fresh pause
                armHoldTimer()
            }
        default:
            holdCheck?.cancel(); holdCheck = nil
        }
    }

    /// (Re)start the "held still" countdown — each pencil movement resets it; when it fires, the pencil has
    /// been stationary long enough to mean "snap this".
    private func armHoldTimer() {
        holdCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.shapeSnapArmed else { return }
            self.shapeSnapArmed = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()   // subtle "ready to snap" cue
            self.onStatus?("Hold detected — lift to snap")              // visible confirmation the hold registered
        }
        holdCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + shapeHoldSeconds, execute: work)
    }

    /// True if the stroke ended with the pencil held roughly still for `shapeHoldSeconds`, read from the
    /// stroke's OWN trailing samples. Apple Pencil keeps streaming samples while ~stationary, so a hold
    /// shows up as a cluster of final points within `shapeDwellRadius` spanning ≥0.5s of timeOffset — a
    /// gesture-independent fallback that works even when the live drawing-gesture signal doesn't fire.
    private func strokeEndedWithHold(_ stroke: PKStroke) -> Bool {
        let path = stroke.path
        guard let last = path.last else { return false }
        let lastLoc = last.location.applying(stroke.transform)
        var dwellStartTime = last.timeOffset
        for p in path.reversed() {
            let loc = p.location.applying(stroke.transform)
            if hypot(loc.x - lastLoc.x, loc.y - lastLoc.y) > shapeDwellRadius { break }
            dwellStartTime = p.timeOffset
        }
        return last.timeOffset - dwellStartTime >= shapeHoldSeconds
    }

    /// Snap the just-finished stroke to a clean line/shape. Returns true if it snapped — recorded as ITS
    /// OWN undo step, so one undo reverts to the freehand sketch (undo again removes it entirely).
    private func snapLastStrokeToShape() -> Bool {
        guard let original = canvasView.drawing.strokes.last else { return false }
        let pts = PencilKitAdapters.hitTestPoints(original).map { Point(x: $0.x, y: $0.y) }
        guard let shape = recognizeShape(pts) else { return false }
        let freehand = canvasView.drawing
        var strokes = freehand.strokes
        strokes[strokes.count - 1] = cleanStroke(for: shape, like: original)
        let snapped = PKDrawing(strokes: strokes)
        setCanvasDrawing(snapped)
        recordStep(.ink(before: freehand, after: snapped))
        lastDrawing = snapped
        // Mark the snapped shape consumed so the auto-"@" scan skips it — but ONLY when there's no EARLIER
        // un-scanned ink (e.g. an "@" command written moments before), so a snap never swallows it.
        if consumedStrokeCount >= snapped.strokes.count - 1 { consumedStrokeCount = snapped.strokes.count }
        scheduleInkSave()
        onStatus?("Snapped to a \(shapeName(shape)) — undo (↩) to keep your sketch")
        return true
    }

    private func shapeName(_ s: RecognizedShape) -> String {
        switch s {
        case .line:    return "line"
        case .arrow:   return "arrow"
        case .ellipse(_, let rx, let ry): return abs(rx - ry) < 0.5 ? "circle" : "ellipse"
        case .polygon(let v, _): return v.count == 3 ? "triangle" : v.count == 4 ? "rectangle" : "shape"
        }
    }

    /// Build a clean PKStroke for a recognized shape, matching the original ink (type / colour / width).
    private func cleanStroke(for shape: RecognizedShape, like original: PKStroke) -> PKStroke {
        let template = original.path.first
        let size = template?.size ?? CGSize(width: 4, height: 4)
        let opacity = template?.opacity ?? 1
        let azimuth = template?.azimuth ?? 0
        let altitude = template?.altitude ?? (.pi / 2)
        let points = shapePolyline(shape).enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: TimeInterval(i) * 0.01, size: size,
                          opacity: opacity, force: 1, azimuth: azimuth, altitude: altitude)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: original.path.creationDate)
        return PKStroke(ink: original.ink, path: path)
    }

    /// A densely-sampled point path for a clean shape (straight runs sampled finely so the rendered
    /// B-spline stays straight; polygon corners reinforced with duplicate points so they read as crisp).
    private func shapePolyline(_ shape: RecognizedShape) -> [CGPoint] {
        func cg(_ p: Point) -> CGPoint { CGPoint(x: p.x, y: p.y) }
        func seg(_ a: CGPoint, _ b: CGPoint) -> [CGPoint] {
            let n = max(2, Int((hypot(b.x - a.x, b.y - a.y) / 4).rounded()))
            return (0...n).map { i in let t = CGFloat(i) / CGFloat(n)
                return CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y)) }
        }
        switch shape {
        case .line(let a, let b):
            return seg(cg(a), cg(b))
        case .arrow(let a, let b):
            let tail = cg(a), tip = cg(b)
            var pts = seg(tail, tip)
            let dx = tip.x - tail.x, dy = tip.y - tail.y
            let len = max(hypot(dx, dy), 0.0001), ux = dx / len, uy = dy / len
            let head = min(22, len * 0.28), ang: CGFloat = 26.0 * .pi / 180
            func rot(_ x: CGFloat, _ y: CGFloat, _ a: CGFloat) -> CGPoint {
                CGPoint(x: x * cos(a) - y * sin(a), y: x * sin(a) + y * cos(a))
            }
            let l = rot(-ux, -uy, ang), r = rot(-ux, -uy, -ang)
            pts += seg(tip, CGPoint(x: tip.x + l.x * head, y: tip.y + l.y * head))
            pts += seg(CGPoint(x: tip.x + l.x * head, y: tip.y + l.y * head), tip)
            pts += seg(tip, CGPoint(x: tip.x + r.x * head, y: tip.y + r.y * head))
            return pts
        case .ellipse(let c, let rx, let ry):
            let n = 64
            return (0...n).map { i in let a = 2 * Double.pi * Double(i) / Double(n)
                return CGPoint(x: c.x + rx * cos(a), y: c.y + ry * sin(a)) }
        case .polygon(let verts, let closed):
            guard verts.count >= 2 else { return verts.map(cg) }
            let ring = closed ? verts + [verts[0]] : verts
            var pts: [CGPoint] = []
            for i in 0..<(ring.count - 1) {
                pts += seg(cg(ring[i]), cg(ring[i + 1]))
                if i < ring.count - 2 { let v = cg(ring[i + 1]); pts += [v, v] }   // sharpen interior corners
            }
            return pts
        }
    }

    // MARK: - Lasso move (drag a selected set of ink + objects; one combined undo step)

    private func beginMove(at p: CGPoint) {
        movingSelection = true
        moveStart = p
        moveObjectStart = [:]
        for id in selectedObjectIDs where store.page.objects[id] != nil { moveObjectStart[id] = store.page.objects[id]!.transform }
        moveInkBefore = selectedStrokeIndices.isEmpty ? nil : canvasView.drawing
        // Lift the selected strokes onto a lightweight snapshot layer so the live drag only translates a
        // GPU layer (O(1) per frame) instead of rebuilding + re-rendering the whole PKDrawing every
        // touch-move. The originals are removed from the canvas once, for the duration of the drag.
        if let before = moveInkBefore {
            let indices = Set(selectedStrokeIndices)
            let selected = PKDrawing(strokes: before.strokes.enumerated().filter { indices.contains($0.offset) }.map(\.element))
            let bounds = selected.bounds
            if !bounds.isNull, !bounds.isEmpty {
                let scale = max(overlay.window?.windowScene?.screen.scale ?? UIScreen.main.scale, 1)
                let layer = CALayer()
                layer.contentsScale = scale
                layer.contents = selected.image(from: bounds, scale: scale).cgImage
                layer.frame = bounds                       // content coords — matches the scrolled overlay
                overlay.layer.insertSublayer(layer, at: 0) // below the marquee + objects, like real ink
                dragInkPreviewLayer = layer
                canvasView.drawing = drawingRemoving(before, indices: indices)   // hide originals (one re-render; guarded by movingSelection)
            }
        }
    }

    private func updateMove(to p: CGPoint) {
        let dx = p.x - moveStart.x, dy = p.y - moveStart.y
        // Every per-frame mutation is now a cheap layer/center move. Disable implicit CALayer animations so
        // the marquee + ink snapshot track the finger EXACTLY — otherwise each change eases over the default
        // ~0.25s and the selection visibly trails the drag.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Objects: nudge the host views live (the authoritative position is committed on release).
        for (id, start) in moveObjectStart {
            overlay.nudgeHost(id, to: CGPoint(x: CGFloat(start.x) + CGFloat(start.width) / 2 + dx,
                                              y: CGFloat(start.y) + CGFloat(start.height) / 2 + dy))
        }
        // Marquee + lifted-ink snapshot: slide both with the drag (no PKDrawing rebuild).
        let move = CATransform3DMakeTranslation(dx, dy, 0)
        lassoLayer.transform = move
        dragInkPreviewLayer?.transform = move
        CATransaction.commit()
    }

    private func endMove(to p: CGPoint) {
        movingSelection = false
        let dx = p.x - moveStart.x, dy = p.y - moveStart.y
        // Clear the live drag transform without an implicit animation; rebakeMarquee re-bakes the path at
        // its new home below (a plain assignment here would slide the marquee back to origin over ~0.25s).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lassoLayer.transform = CATransform3DIdentity
        CATransaction.commit()
        // Object transforms → ONE journal transaction.
        var ops: [OpPayload] = []
        for (id, start) in moveObjectStart {
            let moved = Transform(x: start.x + Double(dx), y: start.y + Double(dy),
                                  width: start.width, height: start.height, rotation: start.rotation)
            ops.append(.setTransform(objectID: id, old: start, new: moved))
        }
        let inkBefore = moveInkBefore
        let inkAfter = inkBefore.map { translatedDrawing($0, indices: Set(selectedStrokeIndices), dx: dx, dy: dy) }
        commitCompound(objectOps: ops, inkBefore: inkBefore, inkAfter: inkAfter, status: "Moved — undo (↩) to put it back")
        clearDragInkPreview()   // the real (crisp) moved drawing is now in the canvas — drop the snapshot
        // Keep the selection at its new home so it can be moved again (or read by Recognize/Check/Fit).
        if let r = lastLassoRect { lastLassoRect = r.offsetBy(dx: dx, dy: dy) }
        selectionMarquee = selectionMarquee.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        rebakeMarquee()
        moveObjectStart = [:]; moveInkBefore = nil
    }

    private func cancelMove() {
        movingSelection = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lassoLayer.transform = CATransform3DIdentity
        CATransaction.commit()
        // Snap everything back to its pre-drag position.
        for id in moveObjectStart.keys where store.page.objects[id] != nil {
            let t = store.page.objects[id]!.transform
            overlay.nudgeHost(id, to: CGPoint(x: CGFloat(t.x) + CGFloat(t.width) / 2, y: CGFloat(t.y) + CGFloat(t.height) / 2))
        }
        if let inkBefore = moveInkBefore { restoreDrawing(inkBefore) }
        clearDragInkPreview()
        moveObjectStart = [:]; moveInkBefore = nil
    }

    /// Tear down the live ink-drag snapshot layer (after a move commits or cancels).
    private func clearDragInkPreview() {
        dragInkPreviewLayer?.removeFromSuperlayer()
        dragInkPreviewLayer = nil
    }

    /// Rebuild a drawing with `indices` strokes translated by (dx, dy) — moving handwriting without the journal.
    private func translatedDrawing(_ drawing: PKDrawing, indices: Set<Int>, dx: CGFloat, dy: CGFloat) -> PKDrawing {
        guard !indices.isEmpty, dx != 0 || dy != 0 else { return drawing }
        let t = CGAffineTransform(translationX: dx, y: dy)
        let moved = drawing.strokes.enumerated().map { i, stroke -> PKStroke in
            guard indices.contains(i) else { return stroke }
            var s = stroke
            s.transform = s.transform.concatenating(t)
            return s
        }
        return PKDrawing(strokes: moved)
    }

    private func rebakeMarquee() {
        guard selectionMarquee.count >= 3 else { return }
        let path = UIBezierPath()
        path.move(to: selectionMarquee[0])
        for pt in selectionMarquee.dropFirst() { path.addLine(to: pt) }
        path.close()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lassoLayer.path = path.cgPath
        CATransaction.commit()
    }

    /// Apply an ink change (before→after drawing) and/or a single object journal transaction, recorded as
    /// ONE undo step. Shared by move / delete / cut / paste so a mixed ink+object edit always reverses in
    /// a single undo, even though ink isn't in the journal.
    private func commitCompound(objectOps: [OpPayload], inkBefore: PKDrawing?, inkAfter: PKDrawing?, status: String) {
        if let inkAfter { restoreDrawing(inkAfter); scheduleInkSave() }
        if !objectOps.isEmpty {
            let before = store.page
            store.perform(objectOps)
            refresh(before)
        }
        if inkAfter != nil || !objectOps.isEmpty {
            recordStep(.compound(inkBefore: inkBefore, inkAfter: inkAfter, hasObjects: !objectOps.isEmpty))
            if !status.isEmpty { onStatus?(status) }
        }
    }

    /// Rebuild a drawing without the strokes at `indices` (delete/cut handwriting).
    private func drawingRemoving(_ drawing: PKDrawing, indices: Set<Int>) -> PKDrawing {
        guard !indices.isEmpty else { return drawing }
        let kept = drawing.strokes.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
        return PKDrawing(strokes: kept)
    }

    // MARK: - Lasso delete / cut / copy / paste

    /// Session clipboard (a `static` so paste works across pages AND notebooks within a session). Holds the
    /// copied objects (full transform + payload, for fresh-id duplication) and ink strokes, plus the source
    /// bounds so paste can offset to the visible center while preserving relative layout.
    private struct Clipboard {
        var objects: [(kind: ObjectKind, payload: ObjectPayload, transform: Transform)]
        var strokes: [PKStroke]
        var bounds: CGRect
    }
    private static var clipboard: Clipboard?

    var hasClipboard: Bool { Self.clipboard != nil }

    /// Copy the lasso selection (objects + ink) to the session clipboard. No mutation, no undo step.
    func copySelection() {
        guard hasLassoSelection else { onStatus?("Lasso something first, then copy."); return }
        var objs: [(ObjectKind, ObjectPayload, Transform)] = []
        var rects: [CGRect] = []
        for id in selectedObjectIDs {
            guard let o = store.page.objects[id] else { continue }
            objs.append((o.kind, o.payload, o.transform))
            rects.append(CGRect(x: o.transform.x, y: o.transform.y, width: o.transform.width, height: o.transform.height))
        }
        let idxSet = Set(selectedStrokeIndices)
        var strokes: [PKStroke] = []
        for (i, s) in canvasView.drawing.strokes.enumerated() where idxSet.contains(i) { strokes.append(s); rects.append(s.renderBounds) }
        guard !objs.isEmpty || !strokes.isEmpty, let first = rects.first else { return }
        Self.clipboard = Clipboard(objects: objs, strokes: strokes, bounds: rects.dropFirst().reduce(first) { $0.union($1) })
        let n = objs.count + strokes.count
        onStatus?("Copied \(n) item\(n == 1 ? "" : "s")")
    }

    /// Delete the lasso selection (objects + ink) as ONE undo step.
    func deleteSelection() {
        guard hasLassoSelection else { onStatus?("Lasso something first, then delete."); return }
        let ops: [OpPayload] = selectedObjectIDs.compactMap { store.page.objects[$0] != nil ? .delete(objectID: $0) : nil }
        let idxSet = Set(selectedStrokeIndices)
        let inkBefore = idxSet.isEmpty ? nil : canvasView.drawing
        let inkAfter = inkBefore.map { drawingRemoving($0, indices: idxSet) }
        commitCompound(objectOps: ops, inkBefore: inkBefore, inkAfter: inkAfter, status: "Deleted — undo (↩) to bring it back")
        clearLassoSelection()
    }

    /// Cut = copy then delete.
    func cutSelection() {
        guard hasLassoSelection else { onStatus?("Lasso something first, then cut."); return }
        copySelection()
        deleteSelection()
    }

    /// Paste the clipboard at the visible center (offset preserves the copied set's relative layout). New
    /// objects get fresh ids; ink strokes are duplicated. Recorded as ONE undo step; the paste is selected
    /// so it can be dragged immediately.
    func pasteClipboard() {
        guard let clip = Self.clipboard, !(clip.objects.isEmpty && clip.strokes.isEmpty) else { onStatus?("Nothing to paste"); return }
        // Move the clipboard's center to the current visible center (handles cross-page / cross-notebook paste).
        let target = CGPoint(x: view.bounds.midX, y: canvasView.contentOffset.y + view.bounds.midY)
        let dx = target.x - clip.bounds.midX, dy = target.y - clip.bounds.midY

        var ops: [OpPayload] = []
        var pastedIDs = Set<UUID>()
        for o in clip.objects {
            let id = UUID(); pastedIDs.insert(id)
            let t = Transform(x: o.transform.x + Double(dx), y: o.transform.y + Double(dy),
                              width: o.transform.width, height: o.transform.height, rotation: o.transform.rotation)
            let snap = ObjectSnapshot(objectID: id, kind: o.kind, transform: t,
                                      pageID: store.pageID, createdBy: store.notebookID, payload: o.payload)
            ops.append(.addObject(snapshot: snap))
        }

        let inkBefore = clip.strokes.isEmpty ? nil : canvasView.drawing
        var inkAfter: PKDrawing?
        var pastedStrokeIndices: [Int] = []
        if let inkBefore {
            let tf = CGAffineTransform(translationX: dx, y: dy)
            var strokes = inkBefore.strokes
            let start = strokes.count
            for s in clip.strokes { var c = s; c.transform = c.transform.concatenating(tf); strokes.append(c) }
            pastedStrokeIndices = Array(start..<strokes.count)
            inkAfter = PKDrawing(strokes: strokes)
        }

        let n = ops.count + clip.strokes.count
        commitCompound(objectOps: ops, inkBefore: inkBefore, inkAfter: inkAfter, status: "Pasted \(n) item\(n == 1 ? "" : "s")")

        // Select the pasted content (a rectangular marquee around it) so the user can move it right away.
        let r = CGRect(x: clip.bounds.minX + dx, y: clip.bounds.minY + dy, width: clip.bounds.width, height: clip.bounds.height).insetBy(dx: -8, dy: -8)
        selectedObjectIDs = pastedIDs
        overlay.setSelectedObjectIDs(selectedObjectIDs)
        selectedStrokeIndices = pastedStrokeIndices
        lastLassoRect = r
        selectionMarquee = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                            CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        rebakeMarquee()
    }

    // MARK: - Edit-menu + keyboard triggers for delete/cut/copy/paste

    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "Copy", action: #selector(copyCmd), input: "c", modifierFlags: .command),
         UIKeyCommand(title: "Cut", action: #selector(cutCmd), input: "x", modifierFlags: .command),
         UIKeyCommand(title: "Paste", action: #selector(pasteCmd), input: "v", modifierFlags: .command)]
    }
    @objc private func copyCmd() { copySelection() }
    @objc private func cutCmd() { cutSelection() }
    @objc private func pasteCmd() { pasteClipboard() }

    @objc private func handleSelectionTap(_ g: UITapGestureRecognizer) {
        guard overlay.isLassoMode, hasLassoSelection else { return }
        let p = g.location(in: overlay)
        guard lastLassoRect?.contains(p) == true else { return }
        becomeFirstResponder()   // so ⌘C/⌘X/⌘V and the menu actions have a responder
        editMenuInteraction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: p))
    }

    /// Drop the lasso selection — both the armed region (`lastLassoRect`) and the visible marquee, kept
    /// in lockstep so the dashed outline always matches what Recognize/Check will actually read.
    private func clearLassoSelection() {
        lastLassoRect = nil
        lassoLayer.path = nil
        lassoLayer.transform = CATransform3DIdentity
        selectedObjectIDs = []
        overlay.setSelectedObjectIDs([])
        selectedStrokeIndices = []
        selectionMarquee = []
        liveLassoPath.removeAllPoints()
    }

    private func finishLasso() {
        defer { lassoPoints = []; liveLassoPath.removeAllPoints() }
        guard lassoPoints.count >= 3 else { lassoLayer.path = nil; return }
        // Lasso bounds in CONTENT coords (overlay.bounds.origin == contentOffset) so Recognize/Check
        // read just this selection.
        let xs = lassoPoints.map(\.x), ys = lassoPoints.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        lastLassoRect = rect

        // Keep a CLOSED dashed marquee after the finger lifts, so a selection looks like a selection
        // (cleared on the next lasso, on new ink, on a tool switch, or on a page change).
        let closed = UIBezierPath()
        closed.move(to: lassoPoints[0])
        for pt in lassoPoints.dropFirst() { closed.addLine(to: pt) }
        closed.close()
        lassoLayer.path = closed.cgPath

        let polygon = lassoPoints.map { Point(x: Double($0.x), y: Double($0.y)) }
        let selected = selectObjects(in: store.page, lasso: polygon)
        // Ink shares the lasso's CONTENT coords, so hit-test strokes directly (no conversion). Pre-filter
        // by each stroke's renderBounds (cheap) before the per-point polygon test. Keep the matching
        // stroke INDICES (not just a bool) so the selection can be dragged.
        var hitStrokes: [Int] = []
        for (i, stroke) in canvasView.drawing.strokes.enumerated() {
            guard stroke.renderBounds.intersects(rect) else { continue }
            // Hit-test the DENSE rendered path (not the sparse control points) so any stroke whose curve is
            // inside the loop is caught, and with the stroke transform applied so a previously-moved stroke
            // tests at its real on-screen position. Together these ensure everything inside the loop moves.
            let pts = PencilKitAdapters.hitTestPoints(stroke).map { Point(x: $0.x, y: $0.y) }
            if strokeHitTest(strokePoints: pts, lasso: polygon, mode: .intersects) { hitStrokes.append(i) }
        }
        selectedObjectIDs = selected
        overlay.setSelectedObjectIDs(selectedObjectIDs)
        selectedStrokeIndices = hitStrokes
        selectionMarquee = lassoPoints          // remember the loop so the marquee can travel with a move
        if !selected.isEmpty || !hitStrokes.isEmpty {
            becomeFirstResponder()   // enable ⌘C/⌘X/⌘V on the selection
            let parts = [selected.isEmpty ? nil : "\(selected.count) object\(selected.count == 1 ? "" : "s")",
                         hitStrokes.isEmpty ? nil : "\(hitStrokes.count) stroke\(hitStrokes.count == 1 ? "" : "s")"].compactMap { $0 }
            onStatus?("Selected \(parts.joined(separator: " + ")) — drag to move · tap for Cut/Copy/Delete · or Recognize/Check/Tutor/Fit.")
        } else {
            clearLassoSelection()   // empty loop over blank space — nothing armed
            onStatus?("Draw the loop around writing or objects — then drag to move, or tap Recognize / Check / Fit.")
        }
    }
}

// MARK: - Edit menu (Cut / Copy / Delete / Paste) for a lasso selection
extension CanvasViewController: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        var edit: [UIAction] = [
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copySelection() },
            UIAction(title: "Cut", image: UIImage(systemName: "scissors")) { [weak self] _ in self?.cutSelection() },
            UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.deleteSelection() },
        ]
        if Self.clipboard != nil {
            edit.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.pasteClipboard() })
        }
        // Contextual actions on the selection — Recognize / Check / Tutor / Fit act on exactly the lassoed region,
        // so they belong here too (not just the toolbar's ＋ menu).
        let actions: [UIAction] = [
            UIAction(title: "Recognize", image: UIImage(systemName: "text.viewfinder")) { [weak self] _ in self?.recognizeSelectionOrPage() },
            UIAction(title: "Check work", image: UIImage(systemName: "checkmark.seal")) { [weak self] _ in self?.checkWork() },
            UIAction(title: "Tutor", image: UIImage(systemName: "graduationcap")) { [weak self] _ in self?.startTutor() },
            UIAction(title: "Fit graph", image: UIImage(systemName: "chart.xyaxis.line")) { [weak self] _ in self?.fitLassoedSketch() },
        ]
        return UIMenu(children: [UIMenu(options: .displayInline, children: edit),
                                 UIMenu(options: .displayInline, children: actions)])
    }
}
