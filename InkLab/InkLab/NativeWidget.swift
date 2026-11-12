import UIKit
import InkLabKit

/// A native (pure-Swift, on-device) live widget rendered as a canvas object. Tier A of make-real:
/// known objects (calculator, clock, chart…) are correct-by-construction native views, never
/// LLM-generated. Each reports a "settled" state string so the canvas can journal it (one-step undo)
/// and, later, persist it. State is the widget's `jsState` in the `.widget` payload.
protocol NativeWidgetView: AnyObject {
    var widgetKind: String { get }
    var initialState: String { get }
    func loadState(_ json: String)
    /// Called when the widget reaches a meaningful resting state (e.g. a calculation completes), with
    /// the previous and next state JSON so the host can emit one `setObjectState` op = one undo step.
    var onStateCommit: ((_ old: String, _ new: String) -> Void)? { get set }
}

/// Maps a widget kind / an "@" command to a native widget. Adding a widget is a one-line change here.
enum NativeWidgetRegistry {
    /// The native widget kind for a typed "@" command, via the real InkLabRouter intent — or nil.
    static func kind(forCommand raw: String) -> String? {
        switch parseCommand(raw) {
        case .scientificCalculator: return "scientificCalculator"
        default:                    return nil
        }
    }

    static func make(kind: String) -> (UIView & NativeWidgetView)? {
        switch kind {
        case "scientificCalculator": return CalculatorWidgetView()
        case "fitGraph":             return FitGraphView()
        default:                     return nil
        }
    }

    static func title(kind: String) -> String {
        switch kind {
        case "scientificCalculator": return "Calculator"
        case "fitGraph":             return "Best fit"
        default:                     return kind
        }
    }

    /// The full card size (content + header + footer bars).
    static func defaultSize(kind: String) -> CGSize {
        switch kind {
        case "scientificCalculator": return WidgetCard.size(content: CGSize(width: 260, height: 352))
        case "fitGraph":             return WidgetCard.size(content: CGSize(width: 360, height: 272))
        default:                     return WidgetCard.size(content: CGSize(width: 240, height: 212))
        }
    }

    static func initialState(kind: String) -> String { make(kind: kind)?.initialState ?? "{}" }
}
