import SwiftUI

@main
struct InkLabApp: App {
    @StateObject private var library = Library()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(library)
                .environmentObject(settings)
        }
    }
}
