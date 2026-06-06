// swift-tools-version: 6.0
import PackageDescription

// InkLabReactive: reactive worked-solutions (brief §6.5). A dependency graph of cells — change one
// number (a "knob") and every downstream value recomputes in topological order (spreadsheet
// mechanics), with cycle detection. Reuses InkLabMath's parser/expressions; deterministic, CLI-tested.
let package = Package(
    name: "InkLabReactive",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "InkLabReactive", targets: ["InkLabReactive"])],
    dependencies: [.package(path: "../InkLabMath")],
    targets: [
        .target(name: "InkLabReactive",
                dependencies: [.product(name: "InkLabMath", package: "InkLabMath")],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "InkLabReactiveTests", dependencies: ["InkLabReactive"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
