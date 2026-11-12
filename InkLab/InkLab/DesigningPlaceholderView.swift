import UIKit

/// A transient "Claude is designing…" card shown on the canvas exactly where a make-real widget will
/// land, while generation runs in the background. It is NOT a journal object — purely visual,
/// not persisted, not interactive; the host removes it and drops the real widget in its place when the
/// generation finishes (or removes it on failure). Animates a warm shimmer sweep and the striped sun
/// rising over a horizon line (static under Reduce Motion).
final class DesigningPlaceholderView: UIView {
    /// The page the widget will land on. The overlay is shared by every page, so the host hides this card
    /// while another page is showing.
    let pageID: UUID
    private let shimmer = CAGradientLayer()
    /// Clips the sweeping band to the card. The card itself can't clip (that would also clip its shadow),
    /// so without this the band visibly ran past the card's edges.
    private let shimmerClip = UIView()
    private let horizon = UIView()                 // clips the sun so it rises from behind a line
    private let icon = StripedSunView()
    private let titleLabel = UILabel()
    private var dotTimer: Timer?
    private var baseTitle = "Designing"
    private var dotPhase = 0
    private var didStart = false

    init(prompt: String, pageID: UUID, frame: CGRect) {
        self.pageID = pageID
        super.init(frame: frame)
        isUserInteractionEnabled = false           // taps pass through to the canvas
        backgroundColor = Theme.card
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.borderWidth = Theme.chromeWidth
        layer.borderColor = Theme.chrome.cgColor
        layer.shadowColor = UIColor(red: 0.30, green: 0.18, blue: 0.10, alpha: 1).cgColor
        layer.shadowOpacity = 0.10
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)

        // A soft tinted band that sweeps across the card.
        shimmer.colors = [Theme.sun.withAlphaComponent(0).cgColor,
                          Theme.sun.withAlphaComponent(0.16).cgColor,
                          Theme.sun.withAlphaComponent(0).cgColor]
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmerClip.isUserInteractionEnabled = false
        shimmerClip.clipsToBounds = true
        shimmerClip.layer.cornerRadius = 16
        shimmerClip.layer.cornerCurve = .continuous
        shimmerClip.layer.addSublayer(shimmer)
        addSubview(shimmerClip)

        icon.bandColor = Theme.card
        horizon.clipsToBounds = true
        horizon.addSubview(icon)
        let line = UIView()
        line.backgroundColor = Theme.chrome
        line.translatesAutoresizingMaskIntoConstraints = false
        horizon.addSubview(line)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 40), icon.heightAnchor.constraint(equalToConstant: 40),
            icon.centerXAnchor.constraint(equalTo: horizon.centerXAnchor),
            icon.bottomAnchor.constraint(equalTo: horizon.bottomAnchor, constant: 2),
            line.leadingAnchor.constraint(equalTo: horizon.leadingAnchor), line.trailingAnchor.constraint(equalTo: horizon.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: horizon.bottomAnchor), line.heightAnchor.constraint(equalToConstant: 1),
        ])

        titleLabel.text = "Designing"
        titleLabel.font = Theme.title(17)
        titleLabel.textColor = Theme.ink
        titleLabel.textAlignment = .center

        let promptLabel = UILabel()
        promptLabel.text = "“\(prompt)”"
        promptLabel.font = Theme.ui(13)
        promptLabel.textColor = Theme.inkSecondary
        promptLabel.textAlignment = .center
        promptLabel.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [horizon, titleLabel, promptLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            horizon.heightAnchor.constraint(equalToConstant: 42),
            horizon.widthAnchor.constraint(equalToConstant: 72),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        shimmerClip.frame = bounds
        let band = bounds.width * 0.6
        shimmer.bounds = CGRect(x: 0, y: 0, width: band, height: bounds.height)
        shimmer.position = CGPoint(x: band / 2, y: bounds.midY)
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard !didStart, bounds.width > 1 else { return }
        didStart = true
        startDots()
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        // Shimmer band sweeps left→right, forever.
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -bounds.width * 0.3
        sweep.toValue = bounds.width * 1.3
        sweep.duration = 1.5
        sweep.repeatCount = .infinity
        shimmer.add(sweep, forKey: "shimmer")
        // The sun rises over the horizon line and sinks again.
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = 22
        rise.toValue = 0
        rise.duration = 1.1
        rise.autoreverses = true
        rise.repeatCount = .infinity
        rise.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        icon.layer.add(rise, forKey: "rise")
    }

    /// Animated "Designing…" dots (text only, so they run under Reduce Motion too).
    private func startDots() {
        dotTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.dotPhase = (self.dotPhase + 1) % 4
            self.titleLabel.text = self.baseTitle + String(repeating: ".", count: self.dotPhase)
        }
    }

    /// Change the animated status line, e.g. to "Fixing a problem" while a broken first attempt is regenerated.
    func setStatus(_ text: String) {
        baseTitle = text
        titleLabel.text = text
    }

    /// Stop all animation (call before removing).
    func stop() {
        dotTimer?.invalidate(); dotTimer = nil
        shimmer.removeAllAnimations()
        icon.layer.removeAllAnimations()
    }
    deinit { dotTimer?.invalidate() }
}
