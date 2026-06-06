// swift-tools-version: 6.0
import PackageDescription

// InkLabRouter: the intent router + "@" ask-marker (brief §4.2, §4.3, §5.3). Turns an @command or a
// recognized selection into a dispatch — a vetted deterministic engine, a native widget, or the
// generative make-real path — and proposes the AI action chips for a selection. Deterministic,
// CLI-tested. Depends on InkLabRecognition for the formal-structure/domain types.
let package = Package(
    name: "InkLabRouter",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "InkLabRouter", targets: ["InkLabRouter"])],
    dependencies: [.package(path: "../InkLabRecognition")],
    targets: [
        .target(name: "InkLabRouter",
                dependencies: [.product(name: "InkLabRecognition", package: "InkLabRecognition")],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "InkLabRouterTests", dependencies: ["InkLabRouter"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
