import UIKit
import InkLabKit

/// The transparent overlay of live objects above the ink. In pen mode it lets a Pencil touch fall
/// THROUGH empty space (so PencilKit draws) while keeping objects finger-draggable; in lasso mode it
/// captures touches so the lasso can be drawn over anything.
final class ObjectOverlayView: UIView {
    var isLassoMode = false
    var onObjectMoved: ((UUID, Transform) -> Void)?
    /// A live widget reached a resting state (old,new jsState) — the canvas journals it as one undo step.
    var onWidgetState: ((UUID, String, String) -> Void)?
    /// The user tapped an object's ✕ — the canvas deletes it (undoable).
    var onDelete: ((UUID) -> Void)?
    /// The user edited a sticky's text (old,new) — the canvas journals it (undoable).
    var onEditText: ((UUID, String, String) -> Void)?
    /// "Plot from writing": the user tapped ƒ on a widget — recognize the annotation image, drive the widget.
    var onRecognizeAnnotation: ((UUID, UIImage) -> Void)?
    /// Per-widget annotation strokes changed — the canvas persists them.
    var onAnnotationChanged: ((UUID, Data?) -> Void)?
    /// Supplies a widget's saved annotation strokes when its host is (re)created.
    var annotationProvider: ((UUID) -> Data?)?

    private var hosts: [UUID: ObjectHostView] = [:]
    private var scanView: UIView?
    /// Mirrors the app's global Eraser tool so a Pencil rubs out widget ink (instead of drawing on it).
    /// Applied to every existing host and to any host created later.
    private var pencilErasesAnnotations = false

    /// The global tool changed to/from the Eraser — tell every widget's ink layer so a Pencil erases.
    func setPencilErasesAnnotations(_ on: Bool) {
        guard on != pencilErasesAnnotations else { return }
        pencilErasesAnnotations = on
        for host in hosts.values { host.setPencilErasesAnnotation(on) }
    }

    /// Show a "reading…" scan sweep over a region while recognition runs (so the user sees it working).
    func showScan(in rect: CGRect) {
        hideScan()
        guard rect.width > 1, rect.height > 1 else { return }
        let v = UIView(frame: rect)
        v.isUserInteractionEnabled = false
        v.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.10)
        v.layer.cornerRadius = 6
        v.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.5).cgColor
        v.layer.borderWidth = 1
        v.clipsToBounds = true
        let sweep = CAGradientLayer()
        sweep.frame = CGRect(x: 0, y: 0, width: 44, height: rect.height)
        sweep.startPoint = CGPoint(x: 0, y: 0.5); sweep.endPoint = CGPoint(x: 1, y: 0.5)
        sweep.colors = [UIColor.systemBlue.withAlphaComponent(0).cgColor,
                        UIColor.systemBlue.withAlphaComponent(0.45).cgColor,
                        UIColor.systemBlue.withAlphaComponent(0).cgColor]
        v.layer.addSublayer(sweep)
        let anim = CABasicAnimation(keyPath: "position.x")
        anim.fromValue = -22
        anim.toValue = rect.width + 22
        anim.duration = 0.9
        anim.repeatCount = .infinity
        sweep.add(anim, forKey: "sweep")
        addSubview(v)
        scanView = v
    }

    func hideScan() { scanView?.removeFromSuperview(); scanView = nil }

    /// Feed recognized text into a widget's primary input (handwrite → plot).
    func setWidgetInput(_ id: UUID, _ text: String) { hosts[id]?.setWidgetInput(text) }

    /// Live-nudge a host's center during a lasso move (visual only — the committed position is re-applied
    /// from the journal on release via `applyGeometry`).
    func nudgeHost(_ id: UUID, to center: CGPoint) { hosts[id]?.center = center }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if isLassoMode {
            // One finger draws the lasso; let two-finger touches fall through to the canvas (scroll) and
            // the page-swipe behind us, so navigation still works while the lasso tool is active.
            guard (event?.allTouches?.count ?? 1) <= 1 else { return nil }
            // …but still let a tap on an object's ✕ delete through, so a result/object made while lassoing
            // can be removed without first switching tools.
            for host in hosts.values {
                if let chrome = host.chromeHit(convert(point, to: host)) { return chrome }
            }
            return self
        }
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    func apply(_ ops: [ViewOp], page: PageProjection) {
        var zOrderChanged = false
        for op in ops {
            switch op {
            case .add(let snapshot):
                let host = ObjectHostView(objectID: snapshot.objectID)
                host.onMoved = { [weak self] id, t in self?.onObjectMoved?(id, t) }
                host.onWidgetState = { [weak self] id, old, new in self?.onWidgetState?(id, old, new) }
                host.onDelete = { [weak self] id in self?.onDelete?(id) }
                host.onEditText = { [weak self] id, old, new in self?.onEditText?(id, old, new) }
                host.onRecognizeAnnotation = { [weak self] id, img in self?.onRecognizeAnnotation?(id, img) }
                host.onAnnotationChanged = { [weak self] id, data in self?.onAnnotationChanged?(id, data) }
                addSubview(host)
                hosts[snapshot.objectID] = host
                host.setPencilErasesAnnotation(pencilErasesAnnotations)        // honor the live Eraser-tool state
                host.apply(snapshot)
                host.loadAnnotation(annotationProvider?(snapshot.objectID))   // preload saved ink (widgets only)
                zOrderChanged = true
            case .updateTransform(let id, _):
                if let snap = page.objects[id] { hosts[id]?.applyGeometry(snap) }   // geometry only — don't reload content
            case .updateZ(let id, _):
                if let snap = page.objects[id] { hosts[id]?.applyGeometry(snap) }
                zOrderChanged = true
            case .updateProps(let snap):
                hosts[snap.objectID]?.apply(snap)
            case .remove(let id):
                hosts[id]?.removeFromSuperview()
                hosts[id] = nil
                zOrderChanged = true
            }
        }
        // Only re-rank z when membership/order actually changed — not on every drag or state edit.
        guard zOrderChanged else { return }
        let ordered = hosts.values.sorted {
            (page.objects[$0.objectID]?.z ?? FractionalIndex("m")) < (page.objects[$1.objectID]?.z ?? FractionalIndex("m"))
        }
        for (i, host) in ordered.enumerated() { host.layer.zPosition = CGFloat(i) }
    }
}

/// One object on the page. Polymorphic: it renders either a text card (sticky / recognized / callout)
/// OR a live native widget OR a generated (make-real) HTML widget. Every object carries chrome: a ✕
/// to delete it (top-right) and a grip to resize it (bottom-right). Both commit through the journal,
/// so undo restores a deleted object and reverts a resize.
final class ObjectHostView: UIView, UIGestureRecognizerDelegate, UITextViewDelegate {
    let objectID: UUID
    var onMoved: ((UUID, Transform) -> Void)?       // also used for resize (both are transform commits)
    var onWidgetState: ((UUID, String, String) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onEditText: ((UUID, String, String) -> Void)?   // sticky text edited (old,new)
    var onRecognizeAnnotation: ((UUID, UIImage) -> Void)?   // ƒ: recognize my writing → drive the widget
    var onAnnotationChanged: ((UUID, Data?) -> Void)?       // persist the per-widget annotation strokes

    private static let minWidth: CGFloat = 120
    private static let minHeight: CGFloat = 90

    private var current = Transform()
    private var renderedKind: String?

    private let label = UILabel()
    private let textView = UITextView()                 // shown while editing a sticky
    private let doubleTap = UITapGestureRecognizer()
    private var isSticky = false
    private var stickyText = ""
    private var editingOldText = ""
    private let header = UIView()
    private let headerLabel = UILabel()
    private var widget: (UIView & NativeWidgetView)?     // native (Tier A) widget
    private var webWidget: WebWidgetView?                // generated (make-real) HTML widget
    private var annotation: WidgetAnnotationView?        // pencil ink layer over a generated widget
    private var pendingAnnotation: Data?                 // strokes to load once the annotation view exists
    private var pendingPencilErases = false              // global Eraser tool state, applied when annotation exists
    private let annotateButton = UIButton(type: .system) // ✏️ toggle finger-draw annotation
    private let eraseButton = UIButton(type: .system)    // 🧽 toggle finger-erase of annotation
    private let plotButton = UIButton(type: .system)     // ƒ recognize my writing → drive the widget

    private let hostPan = UIPanGestureRecognizer()
    private let headerPan = UIPanGestureRecognizer()

    private let deleteButton = UIButton(type: .system)
    private let resizeHandle = UIView()
    private let resizePan = UIPanGestureRecognizer()
    private var resizeStart = CGSize.zero
    private var resizeTopLeft = CGPoint.zero

    init(objectID: UUID) {
        self.objectID = objectID
        super.init(frame: .zero)
        layer.cornerRadius = 10
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)

        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 16)

        header.backgroundColor = .secondarySystemFill
        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = .secondaryLabel
        header.addSubview(headerLabel)

        // Drag: label objects drag from anywhere; widget objects drag only from their header.
        for g in [hostPan, headerPan] {
            g.addTarget(self, action: #selector(handleDrag(_:)))
            g.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                   NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        }
        hostPan.delegate = self   // so a touch on the resize grip / delete ✕ doesn't also drag the object
        addGestureRecognizer(hostPan)
        header.addGestureRecognizer(headerPan)

        // Delete ✕ (top-right).
        deleteButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)), for: .normal)
        deleteButton.tintColor = .white
        deleteButton.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        deleteButton.layer.cornerRadius = 13
        deleteButton.accessibilityLabel = "Delete"
        deleteButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onDelete?(self.objectID)
        }, for: .touchUpInside)
        addSubview(deleteButton)

        // Widget-only chrome: ✏️ toggles finger-draw annotation, 🧽 toggles finger-erase, ƒ recognizes the
        // writing and drives the widget (handwrite → plot). Hidden unless the host is a generated webwidget.
        configureChrome(annotateButton, systemName: "pencil.tip", action: #selector(toggleAnnotate))
        configureChrome(eraseButton, systemName: "eraser", action: #selector(toggleErase))
        configureChrome(plotButton, systemName: "function", action: #selector(plotFromWriting))
        annotateButton.accessibilityLabel = "Draw on widget"
        eraseButton.accessibilityLabel = "Erase widget drawing"
        plotButton.accessibilityLabel = "Plot from writing"
        annotateButton.isHidden = true; eraseButton.isHidden = true; plotButton.isHidden = true
        addSubview(annotateButton); addSubview(eraseButton); addSubview(plotButton)

        // Resize grip (bottom-right).
        resizeHandle.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        resizeHandle.layer.cornerRadius = 6
        resizeHandle.accessibilityLabel = "Resize"
        let grip = UIImageView(image: UIImage(systemName: "arrow.up.left.and.arrow.down.right",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
        grip.tintColor = .white
        grip.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.addSubview(grip)
        NSLayoutConstraint.activate([grip.centerXAnchor.constraint(equalTo: resizeHandle.centerXAnchor),
                                     grip.centerYAnchor.constraint(equalTo: resizeHandle.centerYAnchor)])
        resizePan.addTarget(self, action: #selector(handleResize(_:)))
        resizePan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                       NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        resizeHandle.addGestureRecognizer(resizePan)
        addSubview(resizeHandle)

        // Editable sticky text: double-tap a sticky to type into it; a "Done" bar finishes.
        textView.isHidden = true
        textView.backgroundColor = .clear
        textView.textColor = .black
        textView.font = .systemFont(ofSize: 16)
        textView.delegate = self
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        let bar = UIToolbar()
        bar.items = [UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                     UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(finishEditing))]
        bar.sizeToFit()
        textView.inputAccessoryView = bar
        addSubview(textView)

        doubleTap.numberOfTapsRequired = 2
        doubleTap.addTarget(self, action: #selector(handleDoubleTap))
        doubleTap.delaysTouchesBegan = false
        doubleTap.cancelsTouchesInView = false
        addGestureRecognizer(doubleTap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureChrome(_ b: UIButton, systemName: String, action: Selector) {
        b.setImage(UIImage(systemName: systemName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)), for: .normal)
        b.tintColor = .secondaryLabel
        b.addTarget(self, action: action, for: .touchUpInside)
    }

    /// ✏️: toggle finger-draw annotation (a Pencil draws regardless). Mutually exclusive with erase.
    @objc private func toggleAnnotate() {
        guard let annotation else { return }
        annotation.isAnnotating.toggle()
        if annotation.isAnnotating { annotation.isErasing = false }
        refreshAnnotationChrome()
    }

    /// 🧽: toggle finger-erase of the annotation (rub out whole strokes). Mutually exclusive with draw.
    @objc private func toggleErase() {
        guard let annotation else { return }
        annotation.isErasing.toggle()
        if annotation.isErasing { annotation.isAnnotating = false }
        refreshAnnotationChrome()
    }

    /// The global Eraser tool selects/deselects → a Pencil erases this widget's ink (not draws). Reflect it
    /// in the header so the widget shows the same "erase mode" cue the page does.
    func setPencilErasesAnnotation(_ on: Bool) {
        pendingPencilErases = on
        annotation?.pencilErases = on
        refreshAnnotationChrome()
    }

    /// Reflect the annotation's draw/erase state in the button tints and the header colour. The 🧽 button
    /// tint tracks the explicit per-widget finger-erase toggle; the header turns red whenever erasing is
    /// active by EITHER route (the toggle or the global Eraser tool), so a Pencil-erases state is visible.
    private func refreshAnnotationChrome() {
        guard let annotation else { return }
        annotateButton.tintColor = annotation.isAnnotating ? .systemBlue : .secondaryLabel
        eraseButton.tintColor = annotation.isErasing ? .systemRed : .secondaryLabel
        let erasing = annotation.isErasing || annotation.pencilErases
        if erasing { header.backgroundColor = UIColor.systemRed.withAlphaComponent(0.18) }
        else if annotation.isAnnotating { header.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.18) }
        else { header.backgroundColor = .secondarySystemFill }
    }

    /// ƒ: recognize the writing on the widget and feed it to the widget's input (handwrite → plot).
    @objc private func plotFromWriting() {
        guard let image = annotation?.rasterizedImage() else { return }
        onRecognizeAnnotation?(objectID, image)
    }

    /// Feed recognized text into the generated widget's primary input.
    func setWidgetInput(_ text: String) { webWidget?.setInput(text) }

    /// The interactive chrome (the ✕ delete) at `point` in THIS view's coords — so the lasso overlay can
    /// let a ✕ tap through even while the lasso tool is active (otherwise you can't remove a result/object
    /// you just made by lassoing).
    func chromeHit(_ point: CGPoint) -> UIView? {
        deleteButton.frame.contains(point) ? deleteButton : nil
    }

    /// Preload a widget's saved annotation strokes (applied once the annotation view exists).
    func loadAnnotation(_ data: Data?) {
        guard let data else { return }
        if let annotation { annotation.load(data) } else { pendingAnnotation = data }
    }

    /// Geometry-only update (position / size / rotation). Does NOT re-run content `update(for:)`, so a
    /// move or resize never reloads a stateful native widget's last-JOURNALED state — which would wipe
    /// any input the user typed but hasn't committed (e.g. an in-progress calculator expression).
    func applyGeometry(_ snapshot: ObjectSnapshot) {
        current = snapshot.transform
        bounds = CGRect(x: 0, y: 0, width: max(8, snapshot.transform.width), height: max(8, snapshot.transform.height))
        center = CGPoint(x: snapshot.transform.x + snapshot.transform.width / 2,
                         y: snapshot.transform.y + snapshot.transform.height / 2)
        transform = CGAffineTransform(rotationAngle: CGFloat(snapshot.transform.rotation))
        setNeedsLayout()
    }

    func apply(_ snapshot: ObjectSnapshot) {
        applyGeometry(snapshot)
        let kind = Self.discriminator(snapshot.payload)
        if kind != renderedKind {
            rebuild(for: kind)
            renderedKind = kind
        }
        update(for: snapshot.payload)
    }

    /// The content "kind" a payload maps to. A change here means rebuild the renderer (promote/insert).
    private static func discriminator(_ payload: ObjectPayload) -> String {
        if case .widget(_, _, let policy) = payload {
            if policy.hasPrefix("native:") { return policy }       // Tier-A native widget
            if policy == "sandboxed" { return "webwidget" }        // generated (make-real) HTML widget
        }
        return "label"
    }

    private func rebuild(for kind: String) {
        widget?.removeFromSuperview(); widget = nil
        webWidget?.removeFromSuperview(); webWidget = nil
        annotation?.removeFromSuperview(); annotation = nil
        label.removeFromSuperview()
        header.removeFromSuperview()
        annotateButton.isHidden = true; eraseButton.isHidden = true; plotButton.isHidden = true

        if kind == "webwidget" {
            let w = WebWidgetView()
            webWidget = w
            addSubview(header)
            addSubview(w)
            // Pencil annotation layer ON TOP of the web view (ink renders over the graph); finger still
            // operates the widget unless the ✏️ toggle is on. Strokes persist via onAnnotationChanged.
            let ann = WidgetAnnotationView()
            ann.onChanged = { [weak self] in guard let self else { return }; self.onAnnotationChanged?(self.objectID, self.annotation?.encoded) }
            ann.pencilErases = pendingPencilErases
            annotation = ann
            addSubview(ann)
            if let pendingAnnotation { ann.load(pendingAnnotation); self.pendingAnnotation = nil }
            annotateButton.isHidden = false; eraseButton.isHidden = false; plotButton.isHidden = false
            refreshAnnotationChrome()   // reset draw/erase tints + header for this fresh annotation layer
            headerLabel.text = "Generated"
            backgroundColor = .systemBackground
            clipsToBounds = true
            layer.borderColor = UIColor.separator.cgColor
            layer.borderWidth = 0.5
            hostPan.isEnabled = false
            headerPan.isEnabled = true
        } else if kind.hasPrefix("native:"), let w = NativeWidgetRegistry.make(kind: String(kind.dropFirst("native:".count))) {
            w.onStateCommit = { [weak self] old, new in
                guard let self else { return }
                self.onWidgetState?(self.objectID, old, new)
            }
            widget = w
            addSubview(header)
            addSubview(w)
            headerLabel.text = NativeWidgetRegistry.title(kind: String(kind.dropFirst("native:".count)))
            backgroundColor = .systemBackground
            clipsToBounds = true
            layer.borderColor = UIColor.separator.cgColor
            layer.borderWidth = 0.5
            hostPan.isEnabled = false
            headerPan.isEnabled = true
        } else {
            // Label card (sticky / recognized / callout / fallback).
            addSubview(label)
            clipsToBounds = false
            layer.borderWidth = 0
            hostPan.isEnabled = true
            headerPan.isEnabled = false
        }
        // Keep the chrome on top of whatever content was just (re)built (incl. the annotation layer).
        bringSubviewToFront(header)
        bringSubviewToFront(plotButton)
        bringSubviewToFront(eraseButton)
        bringSubviewToFront(annotateButton)
        bringSubviewToFront(deleteButton)
        bringSubviewToFront(resizeHandle)
    }

    private func update(for payload: ObjectPayload) {
        isSticky = false
        if let webWidget {
            if case .widget(_, let html, _) = payload { webWidget.loadHTML(html) }
            return
        }
        if let widget {
            if case .widget(_, let jsState, _) = payload { widget.loadState(jsState) }
            return
        }
        switch payload {
        case .sticky(let text, let colorHex):
            isSticky = true
            stickyText = text
            backgroundColor = UIColor(hex: colorHex) ?? .systemYellow
            label.textColor = .black
            label.text = text.isEmpty ? "Sticky" : text
        case .recognized(let body):
            backgroundColor = .secondarySystemBackground
            label.textColor = .label
            label.text = "Read as: \(body.readAs)"
        case .callout(let text, _, _):
            backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
            layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.4).cgColor
            layer.borderWidth = 1
            label.textColor = .label
            label.font = .systemFont(ofSize: 16, weight: .medium)
            label.text = text
        default:
            backgroundColor = .secondarySystemBackground
            label.textColor = .label
            label.text = "Object"
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let body: UIView? = widget ?? webWidget
        if let body {
            let h: CGFloat = 28
            header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
            let chrome: CGFloat = annotateButton.isHidden ? 64 : 124   // reserve room for ✕ (+ ✏️ 🧽 ƒ on widgets)
            headerLabel.frame = CGRect(x: 10, y: 0, width: max(0, bounds.width - chrome), height: h)
            body.frame = CGRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
            annotation?.frame = body.frame
            plotButton.frame = CGRect(x: bounds.width - 109, y: 3, width: 24, height: 22)
            eraseButton.frame = CGRect(x: bounds.width - 82, y: 3, width: 24, height: 22)
            annotateButton.frame = CGRect(x: bounds.width - 55, y: 3, width: 24, height: 22)
        } else {
            label.frame = CGRect(x: 10, y: 8, width: max(0, bounds.width - 34), height: max(0, bounds.height - 16))
            textView.frame = CGRect(x: 4, y: 2, width: max(0, bounds.width - 8), height: max(0, bounds.height - 4))
        }
        deleteButton.frame = CGRect(x: bounds.width - 28, y: 3, width: 26, height: 26)
        resizeHandle.frame = CGRect(x: bounds.width - 26, y: bounds.height - 26, width: 24, height: 24)
        bringSubviewToFront(plotButton)
        bringSubviewToFront(eraseButton)
        bringSubviewToFront(annotateButton)
        bringSubviewToFront(deleteButton)
        bringSubviewToFront(resizeHandle)
    }

    // MARK: - Drag (move)

    @objc private func handleDrag(_ g: UIPanGestureRecognizer) {
        guard let parent = superview else { return }
        switch g.state {
        case .changed:
            let d = g.translation(in: parent)
            center = CGPoint(x: center.x + d.x, y: center.y + d.y)
            g.setTranslation(.zero, in: parent)
        case .ended, .cancelled:
            let newTransform = Transform(x: Double(center.x) - current.width / 2,
                                         y: Double(center.y) - current.height / 2,
                                         width: current.width, height: current.height, rotation: current.rotation)
            onMoved?(objectID, newTransform)
        default:
            break
        }
    }

    // MARK: - Resize (drag the bottom-right grip; top-left stays fixed)

    @objc private func handleResize(_ g: UIPanGestureRecognizer) {
        guard let parent = superview else { return }
        switch g.state {
        case .began:
            resizeStart = bounds.size
            resizeTopLeft = CGPoint(x: current.x, y: current.y)
        case .changed:
            let t = g.translation(in: parent)
            let w = max(Self.minWidth, resizeStart.width + t.x)
            let h = max(Self.minHeight, resizeStart.height + t.y)
            bounds = CGRect(x: 0, y: 0, width: w, height: h)
            center = CGPoint(x: resizeTopLeft.x + w / 2, y: resizeTopLeft.y + h / 2)
            setNeedsLayout()
        case .ended, .cancelled:
            let newTransform = Transform(x: Double(resizeTopLeft.x), y: Double(resizeTopLeft.y),
                                         width: Double(bounds.width), height: Double(bounds.height),
                                         rotation: current.rotation)
            onMoved?(objectID, newTransform)
        default:
            break
        }
    }

    // Keep the object-move pan from also firing when the touch starts on the resize grip or the ✕.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard g == hostPan else { return true }
        let p = touch.location(in: self)
        return !resizeHandle.frame.contains(p) && !deleteButton.frame.contains(p)
    }

    // MARK: - Edit sticky text (double-tap → type → Done)

    @objc private func handleDoubleTap() {
        guard isSticky else { return }                 // only sticky notes are text-editable
        editingOldText = stickyText
        textView.text = (stickyText == "Sticky") ? "" : stickyText   // start fresh on the default label
        label.isHidden = true
        textView.isHidden = false
        hostPan.isEnabled = false                      // don't drag the note while typing
        setNeedsLayout()
        textView.becomeFirstResponder()
    }

    @objc private func finishEditing() { textView.resignFirstResponder() }

    func textViewDidEndEditing(_ tv: UITextView) {
        let new = tv.text ?? ""
        textView.isHidden = true
        label.isHidden = false
        hostPan.isEnabled = true
        if new != editingOldText { onEditText?(objectID, editingOldText, new) }
    }
}
