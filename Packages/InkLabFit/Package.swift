// swift-tools-version: 6.0
import PackageDescription

// InkLabFit: the live lab-notebook fitting core (brief §6.10). Least-squares fits (linear,
// polynomial, exponential, power) with R² goodness-of-fit and parameter standard errors (error
// bars) — deterministic, CLI-tested. Foundation-only.
let package = Package(
    name: "InkLabFit",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "InkLabFit", targets: ["InkLabFit"])],
    targets: [
        .target(name: "InkLabFit", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "InkLabFitTests", dependencies: ["InkLabFit"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
