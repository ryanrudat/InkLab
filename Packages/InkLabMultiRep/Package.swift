// swift-tools-version: 6.0
import PackageDescription

// InkLabMultiRep: linked multi-representation (brief §6.6) — sketch one form and get the others, kept
// in sync. Equation → table (sample the function) and table → equation (auto-pick the best-fitting
// model). Composes InkLabMath (parse/evaluate) and InkLabFit (least squares). Deterministic, CLI-tested.
let package = Package(
    name: "InkLabMultiRep",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "InkLabMultiRep", targets: ["InkLabMultiRep"])],
    dependencies: [
        .package(path: "../InkLabMath"),
        .package(path: "../InkLabFit"),
    ],
    targets: [
        .target(name: "InkLabMultiRep", dependencies: [
            .product(name: "InkLabMath", package: "InkLabMath"),
            .product(name: "InkLabFit", package: "InkLabFit"),
        ], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "InkLabMultiRepTests", dependencies: ["InkLabMultiRep"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
