import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The library — a grid of notebooks you open into the canvas (brief §7). Covers are a single, uniform,
/// slightly-elevated design (a generic notebook with a spine + label), drag-to-reorder, and recolorable.
struct HomeView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var settings: AppSettings
    @State private var showSettings = false
    @State private var dragging: Notebook?
    @State private var recoloring: Notebook?
    @State private var renaming: Notebook?
    @State private var newName = ""
    @State private var contentWidth: CGFloat = 800
    @State private var scrollOffset: CGFloat = 0

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 24)]

    var body: some View {
        NavigationStack {
            ScrollView {
                DesertHeader(notebookCount: library.notebooks.count, scrollOffset: scrollOffset)
                    .frame(height: DesertFrame.height(forWidth: contentWidth))
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                LazyVGrid(columns: columns, spacing: 28) {
                    ForEach(library.notebooks) { notebook in
                        NavigationLink(value: notebook) {
                            NotebookCover(notebook: notebook)
                                .opacity(dragging?.id == notebook.id ? 0.4 : 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("notebookCover")
                        .onDrag {
                            dragging = notebook                                   // long-press to start reordering
                            return NSItemProvider(object: notebook.id.uuidString as NSString)
                        } preview: {
                            NotebookCover(notebook: notebook).frame(width: 150)
                        }
                        .onDrop(of: [.text], delegate: NotebookDropDelegate(item: notebook, library: library, dragging: $dragging))
                        .contextMenu {
                            Button { recoloring = notebook } label: { Label("Change Color", systemImage: "paintpalette") }
                            Button { renaming = notebook; newName = notebook.title } label: { Label("Rename", systemImage: "pencil") }
                            Button(role: .destructive) { library.delete(notebook) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                .padding(24)
                .animation(.default, value: library.notebooks)
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
                scrollOffset = y
            }
            .background(Color.inkPaper.ignoresSafeArea())
            .navigationTitle("InkLab")                         // the back button's label; the header shows the name
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Notebook.self) { notebook in
                CanvasScreen(notebook: notebook)
                    .navigationTitle(notebook.title)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .toolbar {
                ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { _ = library.addNotebook(paper: settings.defaultPaper) } label: { Image(systemName: "plus") }
                        .accessibilityIdentifier("newNotebook")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityIdentifier("settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(settings) }
            .sheet(item: $recoloring) { nb in
                NotebookColorSheet(current: nb.colorHex) { hex in library.setColor(nb.id, hex) }
            }
            .alert("Rename notebook", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") { if let nb = renaming { library.rename(nb.id, to: newName) }; renaming = nil }
            }
        }
    }
}

/// A single, uniform, slightly-elevated notebook cover: a soft color gradient, a darker spine on the
/// binding edge, a thin highlight, and the title "written" on a label area. Identical layout for every
/// notebook (no per-paper-type icon) so the shelf reads as a tidy set.
private struct NotebookCover: View {
    let notebook: Notebook
    private var base: Color { Color(hex: notebook.colorHex) ?? .blue }

    var body: some View {
        ZStack(alignment: .leading) {
            // Cover: a gentle top→bottom gradient gives the flat color some depth.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [base.lighter(0.10), base, base.darker(0.06)],
                                     startPoint: .top, endPoint: .bottom))

            // Spine on the binding edge + a thin inner highlight.
            HStack(spacing: 0) {
                base.darker(0.20).frame(width: 16)
                Color.white.opacity(0.18).frame(width: 1)
                Spacer(minLength: 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            // Title written on a subtle "label" plaque.
            Text(notebook.title.isEmpty ? "Untitled" : notebook.title)
                .font(.custom("Futura-Medium", size: 17, relativeTo: .headline))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.vertical, 10).padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.leading, 14)          // clear the spine
        }
        .aspectRatio(0.76, contentMode: .fit)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.20), radius: 9, x: 0, y: 5)   // elevation
    }
}

/// Recolor a notebook's cover: curated swatches (tap = apply + close) plus a system color picker for a
/// fully custom color (applies live; close when done).
private struct NotebookColorSheet: View {
    let current: String
    let apply: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var custom: Color = .blue
    private let cols = [GridItem(.adaptive(minimum: 56), spacing: 18)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 18) {
                    ForEach(Library.palette, id: \.self) { hex in
                        Button { apply(hex); dismiss() } label: {
                            Circle()
                                .fill(Color(hex: hex) ?? .gray)
                                .frame(width: 52, height: 52)
                                .overlay(Circle().strokeBorder(.primary.opacity(current == hex ? 0.9 : 0.0), lineWidth: 3))
                                .overlay(current == hex ? Image(systemName: "checkmark").font(.headline.bold()).foregroundStyle(.white) : nil)
                                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
                Divider().padding(.horizontal)
                ColorPicker("Custom color", selection: $custom, supportsOpacity: false)
                    .padding()
                    .onChange(of: custom) { _, c in if let hex = c.hexString { apply(hex) } }
            }
            .navigationTitle("Cover Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

/// Reorders the library as the dragged notebook hovers over a cell (the classic SwiftUI grid pattern).
private struct NotebookDropDelegate: DropDelegate {
    let item: Notebook
    let library: Library
    @Binding var dragging: Notebook?

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.id != item.id else { return }
        library.reorder(dragging: dragging.id, over: item.id)
    }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

extension Color {
    init?(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// 6-digit "#RRGGBB" for persistence (nil if the color can't be resolved to sRGB components).
    var hexString: String? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return String(format: "#%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }

    func lighter(_ amount: Double) -> Color { adjust(by: amount) }
    func darker(_ amount: Double) -> Color { adjust(by: -amount) }
    private func adjust(by amount: Double) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
        func clamp(_ x: CGFloat) -> Double { Double(min(max(x + amount, 0), 1)) }
        return Color(.sRGB, red: clamp(r), green: clamp(g), blue: clamp(b), opacity: Double(a))
    }
}
