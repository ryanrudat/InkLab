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
        accessibilityLabel = Self.title(for: command, engine: engine, limit: .max)   // all of it, never shortened
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

    /// "Make “a clock”" for something to generate; "Run “@balance H2 + O2”" for an exact engine. A long
    /// command keeps its start and its end ("a solar system … orbiting"), so a command written over two lines
    /// shows that its last words were picked up.
    static func title(for command: String, engine: Bool, limit: Int = 28) -> String {
        let body = command.drop { $0 == "@" || $0.isWhitespace }.trimmingCharacters(in: .whitespaces)
        let shown = shortened(body, limit: limit)
        return engine ? "Run “@\(shown)”" : "Make “\(shown)”"
    }

    /// `text` cut in the middle, at word breaks where it can, to about `limit` characters.
    static func shortened(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let half = limit / 2
        let words = text.split(separator: " ").map(String.init)
        var head: [String] = [], tail: [String] = []
        var i = 0, j = words.count - 1
        while i < j, (head + [words[i]]).joined(separator: " ").count <= half { head.append(words[i]); i += 1 }
        while j >= i, ([words[j]] + tail).joined(separator: " ").count <= half { tail.insert(words[j], at: 0); j -= 1 }
        guard !head.isEmpty, !tail.isEmpty else {
            return text.prefix(half).trimmingCharacters(in: .whitespaces) + "…" + text.suffix(half - 1).trimmingCharacters(in: .whitespaces)
        }
        return head.joined(separator: " ") + " … " + tail.joined(separator: " ")
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

/// Reading "@" commands out of recognized handwriting.
enum AtCommandText {
    /// The "@" commands in a reading, each as its lines. A command starts at an "@" at the start of a line or
    /// after a space or "(" (so an email address in someone's notes is never one) and carries on over the
    /// lines after it until another command starts: "@a solar system with" / "all eight planets" is one.
    static func commandLines(in text: String) -> [[String]] {
        var commands: [[String]] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = Array(rawLine)
            let starts = line.indices.filter { i in
                line[i] == "@" && (i == 0 || line[i - 1].isWhitespace || line[i - 1] == "(")
            }
            // Words before this line's first "@" carry on the command above (notes before any command don't count).
            let head = String(line[..<(starts.first ?? line.count)]).trimmingCharacters(in: .whitespaces)
            if !head.isEmpty, !commands.isEmpty { commands[commands.count - 1].append(head) }
            for (k, start) in starts.enumerated() {
                let end = k + 1 < starts.count ? starts[k + 1] : line.count
                commands.append([String(line[start..<end]).trimmingCharacters(in: .whitespaces)])
            }
        }
        // A lone "@" with nothing after it anywhere is not a command (on its own line it still starts one).
        return commands.filter { join($0).count > 1 }
    }

    /// The lines of a command as one: joined with a space, or straight on where a word was split with "-".
    static func join(_ lines: [String]) -> String {
        lines.filter { !$0.isEmpty }.reduce("") { text, line in
            if text.isEmpty { return line }
            if text.hasSuffix("-"), let c = line.first, c.isLowercase { return String(text.dropLast()) + line }
            return text + " " + line
        }
    }
}

/// An "@" command still being written. Written at a normal pace it arrives a line at a time, with a pause
/// (a scan) after each: read on its own the next line has no "@" and would be lost. So the command so far is
/// kept, and writing that carries it on, along the same line or on the next line down, joins it.
struct AtDraft: Equatable {
    /// The command up to the line being written ("@a solar system with").
    var before: String
    /// What's been read of the line being written.
    var line: String
    /// Where that line is (content coordinates).
    var lineBand: CGRect
    /// All of the command's ink so far: the chip goes above it.
    var extent: CGRect
    var page: UUID
    var updated: Date

    /// How long a draft waits for more writing.
    static let memory: TimeInterval = 60

    var command: String { AtCommandText.join([before, line]) }

    /// The last command in `read`, written as the strokes `ink` (their bounds); nil if it holds none.
    init?(read: String, ink: [CGRect], page: UUID, now: Date) {
        let rows = InkGeometry.rows(ink)
        guard let lines = AtCommandText.commandLines(in: read).last, let band = rows.last else { return nil }
        before = AtCommandText.join(Array(lines.dropLast()))
        line = lines.last ?? ""
        lineBand = band
        let own = rows.suffix(min(rows.count, max(1, lines.count)))     // the command's own lines, the last ones read
        extent = own.dropFirst().reduce(own.first ?? band) { $0.union($1) }
        self.page = page
        updated = now
    }

    /// The draft carried on by new writing read as `read`, whose ink (with what was written earlier on its line)
    /// is `ink`; nil when it's somewhere else, starts a command of its own, or comes too late.
    func continued(by read: String, at ink: CGRect, now: Date) -> AtDraft? {
        let text = read.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard now.timeIntervalSince(updated) <= Self.memory, !ink.isNull, !text.joined().isEmpty,
              AtCommandText.commandLines(in: read).isEmpty else { return nil }
        let words = AtCommandText.join(text)
        let h = max(16, lineBand.height)
        var next = self
        next.updated = now
        next.extent = extent.union(ink)
        let overlap = min(ink.maxY, lineBand.maxY) - max(ink.minY, lineBand.minY)
        if overlap > 0.5 * min(max(ink.height, 1), max(lineBand.height, 1)) {
            // More of the line being written.
            guard ink.minX - lineBand.maxX <= 4 * h, lineBand.minX - ink.maxX <= 4 * h else { return nil }
            next.lineBand = lineBand.union(ink)
            guard ink.minX <= lineBand.minX + h else {
                next.line = AtCommandText.join([line, words])                   // only the new words were read
                return next
            }
            // The whole line was read again. On the "@" line that reading may have lost the "@" itself (a
            // handwritten "@" is often read as "a" or "o"): keep the words already known and add what follows.
            if before.isEmpty {
                let known = String(line.drop { $0 == "@" || $0.isWhitespace })
                guard !known.isEmpty, let r = words.range(of: known, options: .caseInsensitive) else { return nil }
                next.line = AtCommandText.join([line, words[r.upperBound...].trimmingCharacters(in: .whitespaces)])
            } else {
                next.line = words
            }
            return next
        }
        // The next line down, under the command.
        guard ink.midY > lineBand.maxY, ink.minY - lineBand.maxY <= 1.2 * h,
              ink.minX <= extent.maxX, ink.maxX >= extent.minX - 2 * h else { return nil }
        next.before = command
        next.line = words
        next.lineBand = ink
        return next
    }
}

/// A read "@" command waits to be offered until the student has stopped writing: no new stroke for `quiet`
/// seconds, and the Pencil not hovering over the page (about to write more). Shown while they're still
/// writing, the chip was a guess at a command not finished yet. A newer read replaces the offer (the newest
/// reading of the command wins); a new stroke restarts the wait.
struct AtOfferWait {
    struct Offer: Equatable {
        var commands: [String]
        var near: CGRect
        var page: UUID
    }

    /// How long writing must have stopped before a chip appears.
    static let quiet: TimeInterval = 3

    private(set) var offer: Offer?
    /// When the last stroke was finished.
    var lastStroke = Date.distantPast
    /// The Pencil is over the page, not touching it.
    var hovering = false

    /// What the newest read found to offer (nil: nothing, so nothing is offered).
    mutating func read(_ offer: Offer?) { self.offer = offer }
    mutating func cancel() { offer = nil }

    /// How long from `now` until the offer is due (0: now); nil with nothing to offer, or while the Pencil
    /// hovers (it's due once the Pencil lifts away).
    func wait(now: Date) -> TimeInterval? {
        guard offer != nil, !hovering else { return nil }
        return max(0, Self.quiet - now.timeIntervalSince(lastStroke))
    }

    /// The offer, taken, if it's due at `now`.
    mutating func take(now: Date) -> Offer? {
        guard let w = wait(now: now), w <= 0.02 else { return nil }
        defer { offer = nil }
        return offer
    }
}
