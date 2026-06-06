// swift-tools-version: 6.0
import PackageDescription

// InkLabKit: an umbrella that re-exports all of InkLab's library packages, so an app adds ONE local
// package dependency and writes `import InkLabKit` to get everything (recognition, the journal/object
// model, the canvas geometry, and the math/units/chem/bio engines).
let package = Package(
    name: "InkLabKit",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "InkLabKit", targets: ["InkLabKit"])],
    dependencies: [
        .package(path: "../InkLabRecognition"),
        .package(path: "../InkLabDoc"),
        .package(path: "../InkLabCanvasCore"),
        .package(path: "../InkLabMath"),
        .package(path: "../InkLabUnits"),
        .package(path: "../InkLabChem"),
        .package(path: "../InkLabBio"),
        .package(path: "../InkLabReactive"),
        .package(path: "../InkLabFit"),
        .package(path: "../InkLabMultiRep"),
        .package(path: "../InkLabRouter"),
        .package(path: "../InkLabSearch"),
    ],
    targets: [
        .target(name: "InkLabKit", dependencies: [
            .product(name: "InkLabRecognition", package: "InkLabRecognition"),
            .product(name: "InkLabDoc", package: "InkLabDoc"),
            .product(name: "InkLabCanvasCore", package: "InkLabCanvasCore"),
            .product(name: "InkLabMath", package: "InkLabMath"),
            .product(name: "InkLabUnits", package: "InkLabUnits"),
            .product(name: "InkLabChem", package: "InkLabChem"),
            .product(name: "InkLabBio", package: "InkLabBio"),
            .product(name: "InkLabReactive", package: "InkLabReactive"),
            .product(name: "InkLabFit", package: "InkLabFit"),
            .product(name: "InkLabMultiRep", package: "InkLabMultiRep"),
            .product(name: "InkLabRouter", package: "InkLabRouter"),
            .product(name: "InkLabSearch", package: "InkLabSearch"),
        ], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
