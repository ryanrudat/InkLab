import SwiftUI
import Combine

enum CanvasTool: String, CaseIterable, Identifiable, Sendable {
    case pen, highlighter, eraser, lasso
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        }
    }
}

/// An on-device transcription awaiting the user's review (the editable "Read as" + engine chips).
struct RecognitionDraft: Identifiable, Sendable {
    let id = UUID()
    /// The page whose ink produced this transcription. The review sheet may stay open while navigation
    /// changes, so insertion must not silently jump to whichever page happens to be visible later.
    let pageID: UUID
    var text: String
    var confidence: Double
    var note: String?
}

/// Shared tool state between the SwiftUI chrome and the UIKit canvas. SwiftUI mutates the published
/// properties; the canvas reads them via `updateUIViewController`. One-shot actions are wired to the
/// view controller by closures (set when the canvas is created).
@MainActor final class CanvasModel: ObservableObject {
    @Published var paper: PaperType
    @Published var penColor: Color = Color(hex: "#1E2530") ?? .primary
    @Published var penWidth: CGFloat = 6
    @Published var tool: CanvasTool = .pen
    /// Whether the floating dock is collapsed to its puck. Lives here (not in the SwiftUI view) so the
    /// toolbar-content child can toggle it WITHOUT a closure binding — which would defeat the drag-perf
    /// isolation (dragging the dock must not rebuild the heavy toolbar content).
    @Published var dockCollapsed: Bool = false
    /// Three pen-width presets shown as inline dots (thin / medium / thick). Independent of color —
    /// picking a color never changes the chosen thickness.
    let widthPresets: [CGFloat] = [3, 6, 10]
    /// Saved colors per drawing tool (pen / highlighter), persisted across launches (UserDefaults).
    /// Tapping one changes ONLY the pen color; the thickness above is a separate control left untouched.
    @Published var colorsByTool: [String: [String]] { didSet { Self.saveColors(colorsByTool) } }

    /// The saved colors for the currently-active tool (empty for eraser/lasso).
    var currentColors: [String] { colorsByTool[tool.rawValue] ?? [] }

    /// Apply a saved color to the live pen — color ONLY, so the user's thickness choice is preserved.
    func useColor(_ hex: String) { if let c = Color(hex: hex) { penColor = c } }

    func isActiveColor(_ hex: String) -> Bool {
        penColor.hexString?.caseInsensitiveCompare(hex) == .orderedSame
    }

    /// Save the live pen color as a new swatch for the current tool (deduped, capped at 24).
    func addCurrentColor() {
        guard tool == .pen || tool == .highlighter, let hex = penColor.hexString else { return }
        var arr = colorsByTool[tool.rawValue] ?? []
        guard !arr.contains(where: { $0.caseInsensitiveCompare(hex) == .orderedSame }) else { return }
        arr.append(hex)
        colorsByTool[tool.rawValue] = Array(arr.suffix(24))
    }

    /// Remove a saved color from the current tool's palette.
    func deleteColor(_ hex: String) {
        guard var arr = colorsByTool[tool.rawValue] else { return }
        arr.removeAll { $0.caseInsensitiveCompare(hex) == .orderedSame }
        colorsByTool[tool.rawValue] = arr
    }

    private static let colorsKey = "inklab.penColors.v1"
    private static func saveColors(_ c: [String: [String]]) {
        if let data = try? JSONEncoder().encode(c) { UserDefaults.standard.set(data, forKey: colorsKey) }
    }
    private static func loadColors() -> [String: [String]] {
        if let data = UserDefaults.standard.data(forKey: colorsKey),
           let d = try? JSONDecoder().decode([String: [String]].self, from: data), !d.isEmpty { return d }
        return [
            // Poster inks: charcoal, steel blue, rust, sage, sun, violet; highlighters in the same family.
            CanvasTool.pen.rawValue: ["#1E2530", "#3D6FA3", "#C2452A", "#4E8A5E", "#E8742F", "#7E5AA6"],
            CanvasTool.highlighter.rawValue: ["#FBDA7E", "#B9DDB0", "#F7B8A6", "#B5CCE3"],
        ]
    }
    @Published var fingerDrawing: Bool = true
    @Published var autoCommands: Bool = true
    /// Draw-and-hold shape snapping (hold the pencil still after a stroke → it snaps to a clean shape).
    @Published var snapShapesOnHold: Bool = true
    /// Consent session for make-real generation, mirrored from `AppSettings`. Defaults to "not consented"
    /// so nothing reaches the cloud until the user opts in.
    @Published var makeRealSession = MakeRealSession(isOnline: true, userKind: "adult", aiConsentGranted: false, ageVerified: true)
    @Published var lastResult: String?
    /// Current page indicator for the toolbar (e.g. "2/3", or "1" for a single page).
    @Published var pageIndicator = "1"
    /// Set by the canvas when Vision finishes; presented as the review sheet.
    @Published var pendingRecognition: RecognitionDraft?

    // Actions wired to the view controller:
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onAddSticky: (() -> Void)?
    var onInsertResult: ((String, UUID?) -> Void)?
    var onRecognize: (() -> Void)?
    /// Explicit, on-demand "check my working" — runs the on-device deterministic red-pen tutor (no cloud).
    var onCheckWork: (() -> Void)?
    /// Socratic tutor on the lassoed problem + working: hints and questions, never the answer (Tutor.swift).
    var onTutor: (() -> Void)?
    /// Fit the lassoed sketch (or page) to a best-fit curve → a live, correct graph (InkLabFit, on-device).
    var onFitCurve: (() -> Void)?
    /// Drop a native live widget (e.g. "scientificCalculator") onto the page.
    var onInsertWidget: ((String) -> Void)?
    /// Generate a live widget from a request (the make-real "magic").
    var onMakeReal: ((String) -> Void)?
    /// Page navigation (also reachable via a two-finger horizontal swipe on the canvas).
    var onNextPage: (() -> Void)?
    var onPrevPage: (() -> Void)?

    init(paper: PaperType) {
        self.paper = paper
        self.colorsByTool = Self.loadColors()   // set in init → didSet doesn't fire (no redundant save)
    }
}
