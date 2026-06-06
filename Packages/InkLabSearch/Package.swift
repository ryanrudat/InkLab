// swift-tools-version: 6.0
import PackageDescription

// InkLabSearch: content-aware search over recognized handwriting + typed text across notebooks
// (brief §7 Search). An inverted index with prefix matching and ranking, plus an extractor that
// pulls searchable text from the InkLabDoc journal. Deterministic, CLI-tested.
let package = Package(
    name: "InkLabSearch",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "InkLabSearch", targets: ["InkLabSearch"])],
    dependencies: [.package(path: "../InkLabDoc")],
    targets: [
        .target(name: "InkLabSearch",
                dependencies: [.product(name: "InkLabDoc", package: "InkLabDoc")],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "InkLabSearchTests", dependencies: ["InkLabSearch"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
