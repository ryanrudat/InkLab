// swift-tools-version: 6.0
import PackageDescription

// InkLabCanvasCore: the pure-Swift geometry/selection/paging "brain" of the canvas (brief §12 #2),
// split out so it's unit-testable WITHOUT an iPad. Lasso hit-testing, transform math (move/resize/
// rotate), canvas↔view coordinate mapping, page auto-extend, the page-turn-vs-scroll classifier, and
// the projection→view diff. The PencilKit integration (live ink, zoom crispness, gesture feel) lives
// in the iOS app and is validated by the on-device gate plan (see ADR 0005). Reuses InkLabDoc's
// Transform/projection types and InkLabRecognition's Point/Rect so its output feeds recognition.
let package = Package(
    name: "InkLabCanvasCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "InkLabCanvasCore", targets: ["InkLabCanvasCore"])],
    dependencies: [
        .package(path: "../InkLabDoc"),
        .package(path: "../InkLabRecognition"),
    ],
    targets: [
        .target(name: "InkLabCanvasCore", dependencies: [
            .product(name: "InkLabDoc", package: "InkLabDoc"),
            .product(name: "InkLabRecognition", package: "InkLabRecognition"),
        ], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "InkLabCanvasCoreTests", dependencies: ["InkLabCanvasCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
