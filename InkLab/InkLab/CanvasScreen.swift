import SwiftUI
import UIKit

/// The page editor: the UIKit canvas + a floating SwiftUI toolbar and an "@" command bar that runs
/// the deterministic engines (brief §5, §5.3).
struct CanvasScreen: View {
    let notebook: Notebook
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model: CanvasModel
    @State private var command = ""
    @State private var showCommand = false
    @State private var status: String?
    @FocusState private var commandFocused: Bool

    init(notebook: Notebook) {
        self.notebook = notebook
        _model = StateObject(wrappedValue: CanvasModel(paper: notebook.paper))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CanvasRepresentable(model: model, onStatus: { showStatus($0) })
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if showCommand { commandBar.transition(.move(edge: .top).combined(with: .opacity)) }
                Spacer()
            }

            if let status { statusToast(status) }
            toolbar.padding(.bottom, 10)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation { showCommand.toggle() }
                    commandFocused = showCommand
                } label: { Image(systemName: "at.circle\(showCommand ? ".fill" : "")") }
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 16) {
            ForEach(CanvasTool.allCases) { tool in
                Button { model.tool = tool } label: { Image(systemName: tool.systemImage) }
                    .foregroundStyle(model.tool == tool ? Color.accentColor : .secondary)
            }
            divider
            ColorPicker("", selection: $model.penColor, supportsOpacity: false).labelsHidden().frame(width: 28)
            Menu {
                Button("Thin") { model.penWidth = 2 }
                Button("Medium") { model.penWidth = 4 }
                Button("Thick") { model.penWidth = 8 }
            } label: { Image(systemName: "lineweight") }
            divider
            Menu {
                ForEach(PaperType.allCases) { p in
                    Button { model.paper = p } label: { Label(p.label, systemImage: p.systemImage) }
                }
            } label: { Image(systemName: "doc") }
            Button { model.onAddSticky?() } label: { Image(systemName: "note.text.badge.plus") }
            divider
            Button { model.onUndo?() } label: { Image(systemName: "arrow.uturn.backward") }
            Button { model.onRedo?() } label: { Image(systemName: "arrow.uturn.forward") }
        }
        .font(.title3)
        .foregroundStyle(.primary)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 5, y: 2)
    }

    private var divider: some View { Divider().frame(height: 22) }

    // MARK: Command bar

    private var commandBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "at").foregroundStyle(.secondary)
            TextField("@balance H2 + O2 -> H2O  ·  @molar C6H12O6  ·  @units 5 m + 3 s  ·  @transcribe ATGGCC", text: $command)
                .focused($commandFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(runCmd)
            Button("Run", action: runCmd).disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12).padding(.top, 8)
    }

    private func runCmd() {
        let text = command.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let result = runCommand(text)
        model.onInsertResult?(result)
        showStatus(result)
        command = ""
    }

    // MARK: Status toast

    private func statusToast(_ s: String) -> some View {
        Text(s)
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 3)
            .padding(.bottom, 80)
            .transition(.opacity)
    }

    private func showStatus(_ s: String) {
        withAnimation { status = s }
        Task {
            try? await Task.sleep(for: .seconds(2.8))
            withAnimation { if status == s { status = nil } }
        }
    }
}

/// Bridges the SwiftUI tool state to the UIKit canvas.
private struct CanvasRepresentable: UIViewControllerRepresentable {
    @ObservedObject var model: CanvasModel
    var onStatus: (String) -> Void

    func makeUIViewController(context: Context) -> CanvasViewController {
        let vc = CanvasViewController()
        vc.onStatus = onStatus
        model.onUndo = { [weak vc] in vc?.performUndo() }
        model.onRedo = { [weak vc] in vc?.performRedo() }
        model.onAddSticky = { [weak vc] in vc?.addSticky() }
        model.onInsertResult = { [weak vc] t in vc?.insertResult(t) }
        vc.apply(paper: model.paper, penColor: UIColor(model.penColor), penWidth: model.penWidth, tool: model.tool)
        return vc
    }

    func updateUIViewController(_ vc: CanvasViewController, context: Context) {
        vc.apply(paper: model.paper, penColor: UIColor(model.penColor), penWidth: model.penWidth, tool: model.tool)
    }
}
