import SwiftUI

/// Shown after Vision reads the page ink: the editable "Read as" transcription plus engine chips.
/// Editing keeps the loop honest and testable even when OCR misreads mouse-drawn handwriting in the
/// Simulator — fix the text, pick an engine, drop the (correct-by-construction) result on the page.
struct RecognitionReviewView: View {
    let draft: RecognitionDraft
    var onAddToPage: (String) -> Void

    @State private var text: String
    @State private var result: String?
    @State private var lastAction: EngineAction?
    @Environment(\.dismiss) private var dismiss

    init(draft: RecognitionDraft, onAddToPage: @escaping (String) -> Void) {
        self.draft = draft
        self.onAddToPage = onAddToPage
        _text = State(initialValue: draft.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 90)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Read as")
                } footer: {
                    Text("Vision read this on-device (\(Int((draft.confidence * 100).rounded()))% confidence). Fix any misreads, then pick an engine. Put one step per line for “Check working”.")
                }

                Section("Run an engine") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(EngineAction.allCases) { action in
                                Button {
                                    lastAction = action
                                    result = runEngine(action, on: text)
                                } label: {
                                    Label(action.rawValue, systemImage: action.systemImage)
                                        .font(.callout)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(lastAction == action
                                                    ? Color.accentColor.opacity(0.18)
                                                    : Color(.secondarySystemBackground),
                                                    in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }

                if let result {
                    Section("Result") {
                        Text(result).font(.system(.body, design: .rounded))
                        Button {
                            onAddToPage(result)
                            dismiss()
                        } label: {
                            Label("Add to page", systemImage: "plus.circle.fill")
                        }
                    }
                }
            }
            .navigationTitle("Recognized")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }
}
