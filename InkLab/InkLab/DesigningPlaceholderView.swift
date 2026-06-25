import UIKit

/// A transient "Claude is designing…" card shown on the canvas exactly where a make-real widget will
/// land, while generation runs in the background (~20s). It is NOT a journal object — purely visual,
/// not persisted, not interactive; the host removes it and drops the real widget in its place when the
/// generation finishes (or removes it on failure). Animates a shimmer sweep + a breathing sparkle.
final class DesigningPlaceholderView: UIView {
    private let shimmer = CAGradientLayer()
    private let icon = UIImageView(image: UIImage(systemName: "sparkles"))
    private let titleLabel = UILabel()
    private var dotTimer: Timer?
    private var dotPhase = 0
    private var didStart = false

    init(prompt: String, frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false           // taps pass through to the canvas
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.separator.withAlphaComponent(0.4).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.08
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)

        // A soft tinted band that sweeps across the card.
        shimmer.colors = [UIColor.systemBlue.withAlphaComponent(0).cgColor,
                          UIColor.systemBlue.withAlphaComponent(0.20).cgColor,
                          UIColor.systemBlue.withAlphaComponent(0).cgColor]
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.cornerRadius = 16
        layer.addSublayer(shimmer)

        icon.tintColor = .systemBlue
        icon.contentMode = .center
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .regular)

        titleLabel.text = "Designing"
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center

        let promptLabel = UILabel()
        promptLabel.text = "“\(prompt)”"
        promptLabel.font = .systemFont(ofSize: 13)
        promptLabel.textColor = .tertiaryLabel
        promptLabel.textAlignment = .center
        promptLabel.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, promptLabel])
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
            icon.heightAnchor.constraint(equalToConstant: 42),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let band = bounds.width * 0.6
        shimmer.bounds = CGRect(x: 0, y: 0, width: band, height: bounds.height)
        shimmer.position = CGPoint(x: band / 2, y: bounds.midY)
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard !didStart, bounds.width > 1 else { return }
        didStart = true
        // Shimmer band sweeps left→right, forever.
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -bounds.width * 0.3
        sweep.toValue = bounds.width * 1.3
        sweep.duration = 1.5
        sweep.repeatCount = .infinity
        shimmer.add(sweep, forKey: "shimmer")
        // Breathing sparkle.
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.9
        pulse.toValue = 1.12
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        icon.layer.add(pulse, forKey: "pulse")
        // Animated "Designing…" dots.
        dotTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.dotPhase = (self.dotPhase + 1) % 4
            self.titleLabel.text = "Designing" + String(repeating: ".", count: self.dotPhase)
        }
    }

    /// Stop all animation (call before removing).
    func stop() {
        dotTimer?.invalidate(); dotTimer = nil
        shimmer.removeAllAnimations()
        icon.layer.removeAllAnimations()
    }
    deinit { dotTimer?.invalidate() }
}
