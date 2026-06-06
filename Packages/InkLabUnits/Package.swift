// swift-tools-version: 6.0
import PackageDescription

// InkLabUnits: the "dimensional conscience" (brief §6.7). Tracks units through a calculation and
// flags dimensional mismatches deterministically — adding metres to seconds, a non-dimensionless
// function argument, or an equation whose sides don't match. Correct by construction; the model only
// READS the formula, this engine COMPUTES the dimensional verdict. Foundation-only, CLI-testable.
let package = Package(
    name: "InkLabUnits",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "InkLabUnits", targets: ["InkLabUnits"])],
    targets: [
        .target(name: "InkLabUnits", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "InkLabUnitsTests", dependencies: ["InkLabUnits"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
