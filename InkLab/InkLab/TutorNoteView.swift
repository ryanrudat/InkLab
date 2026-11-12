import UIKit
import InkLabKit

/// Everything the tutor's margin note looks like — colours, fonts, shapes, spacing — in one place, so the
/// app theme can restyle it without touching layout code. Styled from `Theme`: the tutor wears the sun
/// (a warm sand card, a Futura header in sun orange, sun-orange controls and connector); engine results
/// elsewhere wear steel, so the two never read as the same voice.
struct TutorNoteStyle {
    var width: CGFloat = 280
    var padding: CGFloat = 12
    var spacing: CGFloat = 6
    var cornerRadius: CGFloat = 14
    var borderWidth: CGFloat = 1
    var background: UIColor = Theme.sandTint
    var border: UIColor = Theme.sun.withAlphaComponent(0.35)
    var shadowOpacity: Float = 0.10
    var shadowRadius: CGFloat = 6

    var headerFont: UIFont = Theme.title(13)
    var headerColor: UIColor = Theme.sun
    var bodyFont: UIFont = Theme.ui(15)
    var bodyColor: UIColor = Theme.ink
    var threadFont: UIFont = Theme.ui(13)
    var threadColor: UIColor = Theme.inkSecondary
    var studentColor: UIColor = Theme.ink
    var checkFollows: UIColor = Theme.sage
    var checkDoesNotFollow: UIColor = Theme.rust
    var checkUnknown: UIColor = Theme.inkSecondary

    var controlFont: UIFont = Theme.ui(13, .semibold)
    var controlTint: UIColor = Theme.sun

    var connectorColor: UIColor = Theme.sun.withAlphaComponent(0.6)
    var connectorWidth: CGFloat = 1
    var anchorDotRadius: CGFloat = 2.5
    /// Room at the header's right for the note's ✕ (the host's close button, one per session).
    var closeInset: CGFloat = 30

    /// "Write on the page": the highlighted space where the next ink is read as the reply.
    var writeZoneTint: UIColor = Theme.sun
    var writeZoneFill: UIColor = Theme.sun.withAlphaComponent(0.06)
    var writeZoneHeight: CGFloat = 110
    var writeZoneDash: [NSNumber] = [6, 4]

    static var current = TutorNoteStyle()
}

/// What the student does from the note: answer in ink on the page or typed, or correct what was read.
/// On a note for a problem that couldn't be read, `write` / `type` rewrite or type the problem itself.
enum TutorReplyMode: Equatable { case write, type, fixReading }

/// The tutor's note in the page margin: the latest tutor message, with everything before it (earlier
/// hints, the student's replies and the engine's check of each step) folded into an "N earlier" control,
/// the two ways to reply (write on the page, or type), and a thin connector to the line it is about.
/// Rendered from the session in the note's provenance — the note holds no state of its own beyond
/// whether the thread is expanded.
final class TutorNoteView: UIView {
    var onReply: ((TutorReplyMode) -> Void)?
    /// Expanding/collapsing changes the note's height: the host re-fits itself.
    var onResize: (() -> Void)?
    /// The anchored line's right end, in this view's coordinates (set by the host; nil = no connector).
    var anchorInSelf: CGPoint? { didSet { updateConnector() } }

    private(set) var isExpanded = false
    private var style: TutorNoteStyle { .current }
    private var provenance: TutorCalloutProvenance?

    private let header = UILabel()
    /// "I read: 7 + 3 =": what the reading came back as, quiet, tap to correct it.
    private let readAsButton = UIButton(type: .system)
    private let earlierButton = UIButton(type: .system)
    private var threadLabels: [UILabel] = []
    private let message = UILabel()
    private let writeButton = UIButton(type: .system)
    private let typeButton = UIButton(type: .system)
    private let connector = CAShapeLayer()
    private let anchorDot = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "tutorNote"
        for l in [header, message] { l.numberOfLines = 0; addSubview(l) }
        header.accessibilityIdentifier = "tutorHeader"
        message.accessibilityIdentifier = "tutorMessage"
        readAsButton.accessibilityIdentifier = "tutorReadAs"
        readAsButton.contentHorizontalAlignment = .leading
        readAsButton.titleLabel?.numberOfLines = 2
        readAsButton.titleLabel?.lineBreakMode = .byTruncatingTail
        readAsButton.addAction(UIAction { [weak self] _ in self?.onReply?(.fixReading) }, for: .touchUpInside)
        addSubview(readAsButton)
        earlierButton.accessibilityIdentifier = "tutorEarlier"
        earlierButton.contentHorizontalAlignment = .leading
        earlierButton.addAction(UIAction { [weak self] _ in self?.toggleEarlier() }, for: .touchUpInside)
        addSubview(earlierButton)
        for (button, id, mode) in [(writeButton, "tutorReplyWrite", TutorReplyMode.write), (typeButton, "tutorReplyType", .type)] {
            button.accessibilityIdentifier = id
            button.contentHorizontalAlignment = .leading
            button.addAction(UIAction { [weak self] _ in self?.onReply?(mode) }, for: .touchUpInside)
            addSubview(button)
        }
        layer.insertSublayer(connector, at: 0)
        layer.addSublayer(anchorDot)
        applyStyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyStyle() {
        let s = style
        backgroundColor = s.background
        layer.cornerRadius = s.cornerRadius
        layer.borderWidth = s.borderWidth
        layer.borderColor = s.border.cgColor
        layer.shadowOpacity = s.shadowOpacity
        layer.shadowRadius = s.shadowRadius
        layer.shadowOffset = CGSize(width: 0, height: 1)
        header.font = s.headerFont; header.textColor = s.headerColor
        message.font = s.bodyFont; message.textColor = s.bodyColor
        connector.strokeColor = s.connectorColor.cgColor
        connector.fillColor = nil
        connector.lineWidth = s.connectorWidth
        anchorDot.fillColor = s.connectorColor.cgColor
        let unread = provenance?.tutor.isUnread == true
        for (button, title, symbol) in [(writeButton, unread ? "Rewrite it" : "Write on the page", "pencil.tip"),
                                        (typeButton, unread ? "Type it" : "Type", "keyboard")] {
            var c = UIButton.Configuration.plain()
            c.title = title
            c.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
            c.imagePadding = 4
            c.contentInsets = .zero
            c.baseForegroundColor = s.controlTint
            c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { [font = s.controlFont] in
                var a = $0; a.font = font; return a
            }
            button.configuration = c
        }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applyStyle()   // CGColors don't follow dark mode on their own
        configureEarlierButton()
        configureReadAs()
    }

    // MARK: Content

    private var thread: [TutorTurn] { provenance?.tutor.thread ?? [] }
    private var latestIndex: Int? { thread.lastIndex { $0.role == .tutor } }
    /// Everything before the latest tutor message.
    private var earlier: [TutorTurn] { latestIndex.map { Array(thread[..<$0]) } ?? thread }

    func configure(_ p: TutorCalloutProvenance) {
        provenance = p
        header.text = Self.headerText(p.tutor)
        message.text = latestIndex.map { thread[$0].text } ?? ""
        threadLabels.forEach { $0.removeFromSuperview() }
        threadLabels = earlier.map(makeThreadLabel)
        threadLabels.forEach(addSubview)
        if earlier.isEmpty { isExpanded = false }
        configureEarlierButton()
        configureReadAs()
        applyStyle()   // the reply buttons' titles depend on whether the problem could be read
        setNeedsLayout()
    }

    /// "Tutor · hint 2 of 4" while there's something to find; once the working checks out the hint count
    /// means nothing, and a problem that couldn't be read has no hints yet.
    static func headerText(_ session: TutorSession) -> String {
        if session.isUnread { return "Tutor" }
        if case .allValid(_) = session.verdict { return "Tutor · your working checks out" }
        return "Tutor · hint \(session.rung) of \(TutorSession.maxRung)"
    }

    private func configureReadAs() {
        let s = style, read = provenance?.tutor.readAs ?? ""
        readAsButton.isHidden = read.isEmpty
        let title = NSMutableAttributedString(string: "I read: \(read)", attributes: [.font: s.threadFont, .foregroundColor: s.threadColor])
        title.append(NSAttributedString(string: "  ✎", attributes: [.font: s.threadFont, .foregroundColor: s.controlTint]))
        readAsButton.setAttributedTitle(title, for: .normal)
        readAsButton.accessibilityLabel = "I read: \(read)"
        readAsButton.accessibilityHint = "Correct what the tutor read"
    }

    private func makeThreadLabel(_ turn: TutorTurn) -> UILabel {
        let s = style
        let label = UILabel()
        label.numberOfLines = 0
        label.accessibilityIdentifier = "tutorThread"
        if turn.role == .student {
            let text = NSMutableAttributedString(string: "You: \(turn.text)", attributes: [.font: s.threadFont, .foregroundColor: s.studentColor])
            let mark = TutorLayout.checkMark(turn.check)
            if !mark.isEmpty {
                let color: UIColor = turn.check == .follows ? s.checkFollows : turn.check == .doesNotFollow ? s.checkDoesNotFollow : s.checkUnknown
                text.append(NSAttributedString(string: "  \(mark)", attributes: [.font: s.threadFont, .foregroundColor: color]))
            }
            label.attributedText = text
        } else {
            label.font = s.threadFont
            label.textColor = s.threadColor
            label.text = turn.text
        }
        label.isHidden = !isExpanded
        return label
    }

    private func configureEarlierButton() {
        let s = style
        earlierButton.isHidden = earlier.isEmpty
        var c = UIButton.Configuration.plain()
        c.title = isExpanded ? "Hide earlier" : "\(earlier.count) earlier"
        c.image = UIImage(systemName: isExpanded ? "chevron.down" : "chevron.right",
                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        c.imagePadding = 4
        c.contentInsets = .zero
        c.baseForegroundColor = s.controlTint
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { [font = s.controlFont] in
            var a = $0; a.font = font; return a
        }
        earlierButton.configuration = c
    }

    private func toggleEarlier() {
        isExpanded.toggle()
        threadLabels.forEach { $0.isHidden = !isExpanded }
        configureEarlierButton()
        onResize?()
        setNeedsLayout()
    }

    // MARK: Layout

    /// The note's height at `width` (expanded or not), without moving anything.
    func fittingHeight(width: CGFloat) -> CGFloat { layout(width: width, apply: false) }

    /// The collapsed note's height for a session state — what the journal records as its size.
    static func height(for p: TutorCalloutProvenance, width: CGFloat = TutorNoteStyle.current.width) -> CGFloat {
        let v = TutorNoteView()
        v.configure(p)
        return v.fittingHeight(width: width)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = layout(width: bounds.width, apply: true)
        updateConnector()
    }

    private func layout(width: CGFloat, apply: Bool) -> CGFloat {
        let s = style, inner = max(0, width - 2 * s.padding)
        var y = s.padding
        func place(_ v: UIView, height: CGFloat, width w: CGFloat = inner) {
            if apply { v.frame = CGRect(x: s.padding, y: y, width: w, height: height) }
            y += height + s.spacing
        }
        func fit(_ l: UILabel, _ w: CGFloat) -> CGFloat { ceil(l.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height) }

        place(header, height: fit(header, inner - s.closeInset), width: inner - s.closeInset)
        if !readAsButton.isHidden {
            let measure = UILabel()                  // the button's own label may not have its text yet
            measure.numberOfLines = 2                // at most two lines, then "…"
            measure.attributedText = readAsButton.attributedTitle(for: .normal)
            place(readAsButton, height: fit(measure, inner))
        }
        if !earlier.isEmpty {
            place(earlierButton, height: 20)
            if isExpanded { for l in threadLabels { place(l, height: fit(l, inner)) } }
        }
        place(message, height: fit(message, inner))
        // The two ways to reply, side by side.
        let writeWidth = min(inner, ceil(writeButton.sizeThatFits(CGSize(width: inner, height: 24)).width))
        if apply {
            writeButton.frame = CGRect(x: s.padding, y: y, width: writeWidth, height: 24)
            typeButton.frame = CGRect(x: s.padding + writeWidth + 16, y: y, width: max(0, inner - writeWidth - 16), height: 24)
        }
        y += 24 + s.spacing
        return ceil(y - s.spacing + s.padding)
    }

    /// The thin line from the note to the line it is about, with a dot at the line's end. It leaves from
    /// whichever edge faces the line.
    private func updateConnector() {
        guard let a = anchorInSelf, bounds.width > 0 else { connector.path = nil; anchorDot.path = nil; return }
        let path = UIBezierPath()
        if a.x < 0 {
            path.move(to: CGPoint(x: 0, y: min(max(a.y, 14), bounds.height - 14)))
        } else if a.y < 0 {
            path.move(to: CGPoint(x: min(max(a.x, 14), bounds.width - 14), y: 0))
        } else if a.x > bounds.width {
            path.move(to: CGPoint(x: bounds.width, y: min(max(a.y, 14), bounds.height - 14)))
        } else if a.y > bounds.height {
            path.move(to: CGPoint(x: min(max(a.x, 14), bounds.width - 14), y: bounds.height))
        } else {
            connector.path = nil; anchorDot.path = nil; return    // the note sits on the line's end: nothing to draw
        }
        path.addLine(to: a)
        connector.path = path.cgPath
        let r = style.anchorDotRadius
        anchorDot.path = UIBezierPath(ovalIn: CGRect(x: a.x - r, y: a.y - r, width: 2 * r, height: 2 * r)).cgPath
    }

    /// A tappable control at `point` (so the canvas can let it through while the lasso tool is active).
    func controlHit(_ point: CGPoint) -> UIView? {
        [writeButton, typeButton, readAsButton, earlierButton].first { !$0.isHidden && $0.frame.contains(point) }
    }
}

/// "Write on the page": the highlighted space next to the problem where the student's next ink is read as
/// their reply. Ink passes straight through it to the canvas; only its ✕ (stop writing) takes a tap.
final class TutorWriteZoneView: UIView {
    var onCancel: (() -> Void)?
    private let border = CAShapeLayer()
    private let caption = UILabel()
    private let cancel = UIButton(type: .system)
    private var style: TutorNoteStyle { .current }

    static let replyCaption = "Write your reply here. The tutor reads it when you pause."
    static let rewriteCaption = "Write the problem again here, a little larger. The tutor reads it when you pause."

    init(frame: CGRect, caption text: String = TutorWriteZoneView.replyCaption) {
        super.init(frame: frame)
        accessibilityIdentifier = "tutorWriteZone"
        layer.addSublayer(border)
        caption.text = text
        caption.numberOfLines = 2
        caption.accessibilityIdentifier = "tutorWriteHint"
        addSubview(caption)
        cancel.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        cancel.accessibilityLabel = "Stop writing a reply"
        cancel.accessibilityIdentifier = "tutorWriteCancel"
        cancel.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
        addSubview(cancel)
        applyStyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyStyle() {
        let s = style
        border.strokeColor = s.writeZoneTint.cgColor
        border.fillColor = s.writeZoneFill.cgColor
        border.lineWidth = 1.5
        border.lineDashPattern = s.writeZoneDash
        caption.font = s.threadFont
        caption.textColor = s.writeZoneTint
        cancel.tintColor = s.writeZoneTint.withAlphaComponent(0.7)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applyStyle()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        border.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: style.cornerRadius).cgPath
        cancel.frame = CGRect(x: bounds.width - 34, y: 4, width: 30, height: 30)
        caption.frame = CGRect(x: 12, y: 8, width: max(0, bounds.width - 52), height: 36)
    }

    /// Only the ✕ is interactive: the Pencil writes through the rest.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        cancel.frame.insetBy(dx: -6, dy: -6).contains(point) ? cancel : nil
    }
}
