import SwiftUI
import UIKit

@main
struct InkLabApp: App {
    @StateObject private var library = Library()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(library)
                .environmentObject(settings)
                // Settings › Appearance. Applied to the window itself (not `.preferredColorScheme`), so the
                // UIKit canvas and sheets follow too, and "Match iPad" reliably hands control back to the system.
                .onChange(of: settings.appearance, initial: true) { _, appearance in appearance.applyToWindows() }
        }
    }
}
