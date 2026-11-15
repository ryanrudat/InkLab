import UIKit

/// What a handwritten "@" command becomes after a writing pause: a small sun capsule just above the end of
/// the writing, "Make “a clock”". Nothing runs from ink on its own. The student taps the chip to make it;
/// writing on, or leaving it for a few seconds, lets it go. Transient, like the "Designing" card: not a journal object,
/// not saved, and only on the page it was written on.
final class AtCommandChip: UIView {
    let command: String
    let pageID: UUID
    /// The chip was tapped: make it.
    var onMake: (() -> Void)?

    static let height: CGFloat = 36
    static let maxWidth: CGFloat = 320
    /// How long an untouched suggestion stays before it fades.
    static let lifetime: TimeInterval = 12

    private let label = UILabel()
    private let icon = UIImageView()
    private var fadeTimer: Timer?

    init(command: String, engine: Bool, pageID: UUID) {
        self.command = command
        self.pageID = pageID
        super.init(frame: .zero)
        accessibilityIdentifier = "atSuggestion"
        isAccessibilityElement = true
        accessibilityTraits = .button
        let title = Self.title(for: command, engine: engine)
        accessibilityLabel = title
        accessibilityHint = "Makes what you wrote after the @. Keep writing to skip it."

        layer.cornerRadius = Self.height / 2
        layer.cornerCurve = .continuous
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)
        icon.image = UIImage(systemName: Theme.starSymbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        icon.contentMode = .center
        label.text = title
        label.font = Theme.ui(15, .semibold)
        label.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(label)
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: AtCommandChip, _: UITraitCollection) in self.applyColors() }
        // A tap, not a touch: a stroke that happens to start on the chip is not a yes.
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        bounds.size = CGSize(width: Self.width(for: title), height: Self.height)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { fadeTimer?.invalidate() }

    private func applyColors() {
        backgroundColor = Theme.sun
        label.textColor = Theme.onSun
        icon.tintColor = Theme.onSun
        traitCollection.performAsCurrent {
            layer.shadowColor = UIColor(red: 0.30, green: 0.18, blue: 0.10, alpha: 1).cgColor   // warm, like the desert light
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(x: 12, y: 0, width: 16, height: bounds.height)
        label.frame = CGRect(x: 34, y: 0, width: max(0, bounds.width - 34 - 14), height: bounds.height)
    }

    /// "Make “a clock”" for something to generate; "Run “@balance H2 + O2”" for an exact engine.
    static func title(for command: String, engine: Bool) -> String {
        let body = command.drop { $0 == "@" || $0.isWhitespace }.trimmingCharacters(in: .whitespaces)
        let shown = body.count > 28 ? body.prefix(27).trimmingCharacters(in: .whitespaces) + "…" : body
        return engine ? "Run “@\(shown)”" : "Make “\(shown)”"
    }

    static func width(for title: String) -> CGFloat {
        let text = (title as NSString).size(withAttributes: [.font: Theme.ui(15, .semibold)]).width
        return min(maxWidth, ceil(text) + 34 + 14)
    }

    /// Where the chips go (content coordinates): stacked just above the end of the writing they came from,
    /// like a tag on it, so the next words written along the line never land on a chip (a stroke that
    /// starts on one would be lost). Under the writing only when there's no room above. Never off the page.
    static func frames(widths: [CGFloat], near ink: CGRect, canvasWidth: CGFloat) -> [CGRect] {
        let gap: CGFloat = 6
        let stack = CGFloat(widths.count) * height + CGFloat(max(0, widths.count - 1)) * gap
        let top = ink.minY - gap - stack >= 8 ? ink.minY - gap - stack : ink.maxY + gap
        return widths.enumerated().map { i, w in
            let x = min(max(8, ink.maxX - w), max(8, canvasWidth - 8 - w))
            return CGRect(x: x, y: top + CGFloat(i) * (height + gap), width: w, height: height)
        }
    }

    /// Pop in (just a fade under Reduce Motion), then fade on its own if left alone.
    func present() {
        alpha = 0
        if !UIAccessibility.isReduceMotionEnabled { transform = CGAffineTransform(scaleX: 0.85, y: 0.85) }
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0.4) {
            self.alpha = 1
            self.transform = .identity
        }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: Self.lifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func dismiss(animated: Bool = true) {
        fadeTimer?.invalidate(); fadeTimer = nil
        guard animated, window != nil else { removeFromSuperview(); return }
        isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.25, animations: { self.alpha = 0 }, completion: { _ in self.removeFromSuperview() })
    }

    @objc private func tapped() { onMake?() }

    override func accessibilityActivate() -> Bool { onMake?(); return true }
    override func accessibilityPerformEscape() -> Bool { dismiss(); return true }
}
