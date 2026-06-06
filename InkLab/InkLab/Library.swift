import SwiftUI
import Combine

/// Paper styles for a page (brief §5.1 paper picker).
enum PaperType: String, CaseIterable, Identifiable, Codable, Sendable {
    case ruled, grid, dotted, blank
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .ruled: return "line.3.horizontal"
        case .grid: return "grid"
        case .dotted: return "circle.grid.3x3"
        case .blank: return "rectangle"
        }
    }
}

/// A notebook in the library (brief §7 — the writable board of notebooks).
struct Notebook: Identifiable, Hashable, Sendable {
    let id = UUID()
    var title: String
    var paper: PaperType
    var colorHex: String
}

/// The library of notebooks (in-memory for now; CloudKit/GRDB later per ADR 0004).
@MainActor final class Library: ObservableObject {
    @Published var notebooks: [Notebook] = [
        Notebook(title: "Physics", paper: .grid, colorHex: "#4F9DFF"),
        Notebook(title: "Calculus", paper: .ruled, colorHex: "#FFB020"),
        Notebook(title: "Chemistry", paper: .dotted, colorHex: "#34C759"),
    ]

    func addNotebook() -> Notebook {
        let palette = ["#4F9DFF", "#FFB020", "#34C759", "#FF6482", "#AF52DE", "#FF9F0A"]
        let n = Notebook(title: "Untitled", paper: .ruled, colorHex: palette[notebooks.count % palette.count])
        notebooks.append(n)
        return n
    }

    func delete(_ notebook: Notebook) { notebooks.removeAll { $0.id == notebook.id } }
    func rename(_ notebook: Notebook, to title: String) {
        if let i = notebooks.firstIndex(of: notebook) { notebooks[i].title = title }
    }
}

/// App settings (brief §7 Settings).
@MainActor final class AppSettings: ObservableObject {
    @Published var defaultPaper: PaperType = .ruled
    @Published var leftHanded: Bool = false
}
