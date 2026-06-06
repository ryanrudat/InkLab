// swift-tools-version: 6.0
import PackageDescription

// InkLabRecognition: the swappable recognition abstraction for InkLab.
//
// Deliberately PLATFORM-AGNOSTIC (Foundation only, no UIKit/PencilKit/CoreGraphics) so the
// routing/consent logic is unit-testable from the CLI on macOS and portable. The iOS app target
// owns a thin adapter that bridges PencilKit `PKStroke` -> `InkStroke` and `PKDrawing.image(...)`
// -> `RasterImage`, and wires the concrete recognizers (MyScript / Apple Vision / Claude-via-proxy).
//
// See docs/decisions/0001-recognition-provider.md for why this interface exists and what it gates.
let package = Package(
    name: "InkLabRecognition",
    platforms: [
        .iOS(.v18),   // InkLab minimum-version floor (see docs/decisions/0003)
        .macOS(.v14), // so `swift test` runs on the developer Mac / CI
    ],
    products: [
        .library(name: "InkLabRecognition", targets: ["InkLabRecognition"]),
    ],
    targets: [
        .target(
            name: "InkLabRecognition",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "InkLabRecognitionTests",
            dependencies: ["InkLabRecognition"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
