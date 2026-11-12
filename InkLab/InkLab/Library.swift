import SwiftUI
import Combine
import InkLabRecognition

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

/// A notebook in the library (brief §7 — the writable board of notebooks). `Codable` + a STABLE `id`
/// so its journal/ink persist to the same place across launches (ADR 0004).
struct Notebook: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    var title: String
    var paper: PaperType
    var colorHex: String

    init(id: UUID = UUID(), title: String, paper: PaperType, colorHex: String) {
        self.id = id; self.title = title; self.paper = paper; self.colorHex = colorHex
    }
}

/// The library of notebooks. The notebook LIST is persisted to disk (so ids — and thus each notebook's
/// journal/ink storage dir — are stable across launches). CloudKit/GRDB replace the file later (ADR 0004).
@MainActor final class Library: ObservableObject {
    @Published var notebooks: [Notebook] { didSet { save() } }

    private static let storeURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("InkLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.storeURL),
           let saved = try? JSONDecoder().decode([Notebook].self, from: data) {
            notebooks = saved
        } else {
            notebooks = [
                Notebook(title: "Physics", paper: .grid, colorHex: "#4F9DFF"),
                Notebook(title: "Calculus", paper: .ruled, colorHex: "#FFB020"),
                Notebook(title: "Chemistry", paper: .dotted, colorHex: "#34C759"),
            ]
            save()   // seed once so these ids are fixed from here on
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(notebooks) { try? data.write(to: Self.storeURL, options: .atomic) }
    }

    func addNotebook(paper: PaperType = .ruled) -> Notebook {
        let palette = ["#4F9DFF", "#FFB020", "#34C759", "#FF6482", "#AF52DE", "#FF9F0A"]
        let n = Notebook(title: "Untitled", paper: paper, colorHex: palette[notebooks.count % palette.count])
        notebooks.append(n)   // didSet persists
        return n
    }

    func delete(_ notebook: Notebook) {
        notebooks.removeAll { $0.id == notebook.id }            // didSet persists the list
        FileJournalStorage.deleteStore(notebookID: notebook.id)  // remove its journal + ink from disk
    }
    func rename(_ notebook: Notebook, to title: String) {
        if let i = notebooks.firstIndex(of: notebook) { notebooks[i].title = title }
    }
    func rename(_ id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = notebooks.firstIndex(where: { $0.id == id }) else { return }
        notebooks[i].title = t
    }

    /// Curated cover colors offered in the recolor sheet (plus a system color picker for custom).
    static let palette: [String] = ["#4F9DFF", "#FFB020", "#34C759", "#FF6482", "#AF52DE",
                                    "#FF9F0A", "#30B0C7", "#FF3B30", "#5856D6", "#8E8E93"]

    func setColor(_ id: UUID, _ hex: String) {
        guard let i = notebooks.firstIndex(where: { $0.id == id }) else { return }
        notebooks[i].colorHex = hex   // didSet persists
    }

    /// Persist a notebook's paper style so reopening the canvas restores the user's choice. The live paper
    /// picker (canvas dock) writes back here; without this, relaunch reseeds the original/ruled default and
    /// the user's change is lost (ADR 0004). No-op when unchanged so it never triggers a redundant save.
    func setPaper(_ id: UUID, _ paper: PaperType) {
        guard let i = notebooks.firstIndex(where: { $0.id == id }), notebooks[i].paper != paper else { return }
        notebooks[i].paper = paper   // didSet persists
    }

    /// Drag-to-reorder on the home grid: move the dragged notebook to where `targetID` sits.
    func reorder(dragging id: UUID, over targetID: UUID) {
        guard let from = notebooks.firstIndex(where: { $0.id == id }),
              let to = notebooks.firstIndex(where: { $0.id == targetID }), from != to else { return }
        notebooks.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }
}

/// App settings (brief §7 Settings).
@MainActor final class AppSettings: ObservableObject {
    private static let defaultPaperKey = "inklab.defaultPaper.v1"
    /// The paper style NEW notebooks are created with. Persisted (UserDefaults) so the Settings choice
    /// survives relaunch — previously it reset to ruled on every launch and was never even applied to a
    /// new notebook (`addNotebook` hardcoded ruled). Existing notebooks keep their own per-notebook paper.
    @Published var defaultPaper: PaperType { didSet { UserDefaults.standard.set(defaultPaper.rawValue, forKey: Self.defaultPaperKey) } }
    private static let snapShapesKey = "inklab.snapShapesOnHold.v1"
    private static let leftHandedKey = "inklab.leftHanded.v1"
    private static let fingerDrawingKey = "inklab.fingerDrawing.v1"
    private static let autoCommandsKey = "inklab.autoCommands.v1"
    /// Draw-and-hold shape snapping: hold the pencil still after a stroke (~0.5s) and a rough line/shape
    /// snaps to a clean form. Persisted; on by default.
    @Published var snapShapesOnHold: Bool { didSet { UserDefaults.standard.set(snapShapesOnHold, forKey: Self.snapShapesKey) } }
    @Published var leftHanded: Bool { didSet { UserDefaults.standard.set(leftHanded, forKey: Self.leftHandedKey) } }
    /// Allow finger/mouse to draw ink. On by default so the canvas works in the Simulator (which has
    /// no Apple Pencil); turn off on a real iPad for pencil-draws / finger-navigates (ADR 0005).
    @Published var fingerDrawing: Bool { didSet { UserDefaults.standard.set(fingerDrawing, forKey: Self.fingerDrawingKey) } }
    /// Automatically run a handwritten "@…" command after a writing pause (no Recognize tap). Turn off
    /// for distraction-free note-taking.
    @Published var autoCommands: Bool { didSet { UserDefaults.standard.set(autoCommands, forKey: Self.autoCommandsKey) } }

    // MARK: Cloud AI consent (ADR 0002 / App Store §5.1.2(i)) — gates every "@" make-real generation.

    /// The explicit third-party-AI permission. OFF by default — a privacy-policy line is not enough;
    /// every user must opt in before the first cloud call.
    @Published var cloudAIConsentGranted: Bool = false
    /// How the user is classified for consent purposes (set behind a neutral age screen in a full build).
    @Published var userKind: UserKind = .adult
    /// Verifiable parental-consent / age check, required for minors (ignored for adults).
    @Published var ageVerified: Bool = false

    init() {
        // Setting a stored property in init does NOT fire its didSet, so loading the saved value here
        // doesn't write it straight back. Subsequent picker/toggle changes persist via the didSets above.
        defaultPaper = UserDefaults.standard.string(forKey: Self.defaultPaperKey)
            .flatMap(PaperType.init(rawValue:)) ?? .ruled
        snapShapesOnHold = UserDefaults.standard.object(forKey: Self.snapShapesKey) as? Bool ?? true
        leftHanded = UserDefaults.standard.object(forKey: Self.leftHandedKey) as? Bool ?? false
        fingerDrawing = UserDefaults.standard.object(forKey: Self.fingerDrawingKey) as? Bool ?? true
        autoCommands = UserDefaults.standard.object(forKey: Self.autoCommandsKey) as? Bool ?? true
    }

    /// The consent session sent with each make-real request (the server re-checks it — ADR 0002).
    var makeRealSession: MakeRealSession {
        MakeRealSession(isOnline: true,
                        userKind: userKind.wire,
                        aiConsentGranted: cloudAIConsentGranted,
                        ageVerified: userKind == .adult ? true : ageVerified)
    }
}

extension UserKind {
    /// The wire value the Server's `Session.userKind` expects (mirrors `Server/src/types.ts`).
    var wire: String {
        switch self {
        case .adult:            return "adult"
        case .minorConsented:   return "minorConsented"
        case .minorUnconsented: return "minorUnconsented"
        case .schoolManaged:    return "schoolManaged"
        }
    }
    init(wire: String) {
        switch wire {
        case "minorConsented":   self = .minorConsented
        case "minorUnconsented": self = .minorUnconsented
        case "schoolManaged":    self = .schoolManaged
        default:                 self = .adult
        }
    }
    var settingsLabel: String {
        switch self {
        case .adult:            return "Adult"
        case .minorConsented:   return "Minor (parental consent)"
        case .minorUnconsented: return "Minor (no consent)"
        case .schoolManaged:    return "School-managed"
        }
    }
}
