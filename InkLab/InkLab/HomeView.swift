import SwiftUI

/// The library — a grid of notebooks you open into the canvas (brief §7).
struct HomeView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var settings: AppSettings
    @State private var showSettings = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 20)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(library.notebooks) { notebook in
                        NavigationLink(value: notebook) {
                            NotebookCover(notebook: notebook)
                        }
                        .contextMenu {
                            Button(role: .destructive) { library.delete(notebook) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("InkLab")
            .navigationDestination(for: Notebook.self) { notebook in
                CanvasScreen(notebook: notebook)
                    .navigationTitle(notebook.title)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let n = library.addNotebook()
                        _ = n   // created; user taps to open
                    } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(settings) }
        }
    }
}

private struct NotebookCover: View {
    let notebook: Notebook
    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(hex: notebook.colorHex) ?? .blue)
                .aspectRatio(0.78, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    Image(systemName: notebook.paper.systemImage)
                        .font(.title3).foregroundStyle(.white.opacity(0.85)).padding(12)
                }
                .shadow(radius: 3, y: 2)
            Text(notebook.title).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
        }
    }
}

extension Color {
    init?(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
