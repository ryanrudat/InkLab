import SwiftUI

// SwiftUI is the thin app shell; the canvas itself is UIKit/PencilKit (ADR 0005 — UIKit owns the
// per-frame hot path; SwiftUI is only chrome and leaf objects).
@main
struct InkLabApp: App {
    var body: some Scene {
        WindowGroup {
            CanvasContainer().ignoresSafeArea()
        }
    }
}

private struct CanvasContainer: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> CanvasViewController { CanvasViewController() }
    func updateUIViewController(_ controller: CanvasViewController, context: Context) {}
}
