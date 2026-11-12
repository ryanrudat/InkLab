import UIKit
import InkLabKit

/// A scientific calculator whose answers are computed by the InkLabMath CAS (`parseExpr` +
/// `numericValue`) — correct by construction, never a guess. On an unparseable/undefined input it
/// shows "Error" rather than a wrong number (correct-or-silent). It commits a result to the journal
/// on "=" and "C" so each calculation is one undo step.
final class CalculatorWidgetView: UIView, NativeWidgetView {
    let widgetKind = "scientificCalculator"
    var initialState: String { Self.encode("0") }
    var onStateCommit: ((String, String) -> Void)?

    private let display = UILabel()
    private var expr = "0"          // the expression currently shown/edited
    private var committed = "0"     // the last journaled display value
    private var justEvaluated = false

    override init(frame: CGRect) { super.init(frame: frame); build() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: NativeWidgetView

    func loadState(_ json: String) {
        let d = Self.decodeDisplay(json)
        committed = d
        expr = d
        justEvaluated = true        // a loaded value behaves like a fresh result
        refreshDisplay()
    }

    // MARK: State JSON ({"display":"…"})

    private struct State: Codable { var display: String }
    private static func encode(_ d: String) -> String {
        guard let data = try? JSONEncoder().encode(State(display: d)), let s = String(data: data, encoding: .utf8) else {
            return "{\"display\":\"0\"}"
        }
        return s
    }
    private static func decodeDisplay(_ json: String) -> String {
        guard let data = json.data(using: .utf8), let s = try? JSONDecoder().decode(State.self, from: data) else { return "0" }
        return s.display
    }

    // MARK: Input

    private func press(_ key: String) {
        switch key {
        case "C":
            setExpr("0"); justEvaluated = false
            commit(to: "0")
        case "⌫":
            if expr.count <= 1 { setExpr("0") } else { setExpr(String(expr.dropLast())) }
            justEvaluated = false
        case "=":
            evaluate()
        default:
            var e = expr
            if (e == "0" || justEvaluated) && startsValue(key) { e = "" }   // start fresh after a result / from 0
            justEvaluated = false
            setExpr(e + inserted(key))
        }
    }

    private func evaluate() {
        if let result = Self.evaluate(expr) {
            setExpr(result)
            justEvaluated = true
            commit(to: result)
        } else {
            display.text = "Error"
        }
    }

    /// Pure compute: the InkLabMath CAS is the authority. Returns a formatted result, or nil when the
    /// input is unparseable / undefined (the UI then shows "Error" — never a wrong number).
    static func evaluate(_ expr: String) -> String? {
        guard let parsed = try? parseExpr(expr), let v = numericValue(parsed, [:]), v.isFinite else { return nil }
        return format(v)
    }

    /// Journal a resting value as one undo step (guarded against no-op by the canvas).
    private func commit(to value: String) {
        let old = Self.encode(committed)
        committed = value
        onStateCommit?(old, Self.encode(value))
    }

    private func setExpr(_ e: String) { expr = e; refreshDisplay() }
    private func refreshDisplay() {
        display.text = expr.replacingOccurrences(of: "*", with: "×").replacingOccurrences(of: "/", with: "÷")
    }

    private func startsValue(_ key: String) -> Bool {
        if let c = key.first, c.isNumber { return true }
        return ["(", ".", "sin", "cos", "tan", "ln", "log", "√", "π"].contains(key)
    }

    private func inserted(_ key: String) -> String {
        switch key {
        case "×": return "*"
        case "÷": return "/"
        case "−": return "-"
        case "√": return "sqrt("
        case "π": return "3.141592653589793"
        case "sin", "cos", "tan", "ln", "log": return key + "("
        default:  return key
        }
    }

    private static func format(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int(v)) }
        return String(format: "%.10g", v)
    }

    // MARK: Layout

    private func build() {
        backgroundColor = Theme.card
        let digits = UIFont.monospacedDigitSystemFont(ofSize: 30, weight: .regular)
        display.font = digits.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 30) } ?? digits
        display.textColor = Theme.ink
        display.textAlignment = .right
        display.text = "0"
        display.adjustsFontSizeToFitWidth = true
        display.minimumScaleFactor = 0.4
        display.translatesAutoresizingMaskIntoConstraints = false

        let rows = [
            ["C", "⌫", "(", ")"],
            ["sin", "cos", "tan", "√"],
            ["ln", "log", "^", "π"],
            ["7", "8", "9", "÷"],
            ["4", "5", "6", "×"],
            ["1", "2", "3", "−"],
            ["0", ".", "=", "+"],
        ]
        let grid = UIStackView()
        grid.axis = .vertical
        grid.distribution = .fillEqually
        grid.spacing = 1
        grid.translatesAutoresizingMaskIntoConstraints = false
        for row in rows {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.distribution = .fillEqually
            rowStack.spacing = 1
            for key in row { rowStack.addArrangedSubview(makeButton(key)) }
            grid.addArrangedSubview(rowStack)
        }

        addSubview(display)
        addSubview(grid)
        NSLayoutConstraint.activate([
            display.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            display.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            display.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            display.heightAnchor.constraint(equalToConstant: 44),
            grid.topAnchor.constraint(equalTo: display.bottomAnchor, constant: 4),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func makeButton(_ key: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(key, for: .normal)
        b.titleLabel?.font = Theme.ui(18, .medium)
        // Poster keys: "=" is the sun, operators are sun-tinted, functions are steel, digits are paper.
        let functions: Set = ["sin", "cos", "tan", "√", "ln", "log", "^", "π", "(", ")"]
        switch key {
        case "=":
            b.backgroundColor = Theme.sun; b.tintColor = Theme.onSun
        case "÷", "×", "−", "+":
            b.backgroundColor = Theme.sun.withAlphaComponent(0.16); b.tintColor = Theme.sun
        case "C", "⌫":
            b.backgroundColor = Theme.cardBar; b.tintColor = Theme.rust
        case _ where functions.contains(key):
            b.backgroundColor = Theme.steelTint; b.tintColor = Theme.slate
        default:
            b.backgroundColor = Theme.cardBar; b.tintColor = Theme.ink
        }
        b.addAction(UIAction { [weak self] _ in self?.press(key) }, for: .touchUpInside)
        b.accessibilityLabel = accessibilityName(key)
        return b
    }

    private func accessibilityName(_ key: String) -> String {
        switch key {
        case "÷": return "divide"; case "×": return "multiply"; case "−": return "minus"; case "+": return "plus"
        case "√": return "square root"; case "^": return "power"; case "⌫": return "delete"; case "C": return "clear"
        case "=": return "equals"; case "π": return "pi"; default: return key
        }
    }
}
