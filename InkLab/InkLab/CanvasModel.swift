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

/// Shared tool state between the SwiftUI chrome and the UIKit canvas. SwiftUI mutates the published
/// properties; the canvas reads them via `updateUIViewController`. One-shot actions are wired to the
/// view controller by closures (set when the canvas is created).
@MainActor final class CanvasModel: ObservableObject {
    @Published var paper: PaperType
    @Published var penColor: Color = .primary
    @Published var penWidth: CGFloat = 4
    @Published var tool: CanvasTool = .pen
    @Published var lastResult: String?

    // Actions wired to the view controller:
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onAddSticky: (() -> Void)?
    var onInsertResult: ((String) -> Void)?

    init(paper: PaperType) { self.paper = paper }
}
