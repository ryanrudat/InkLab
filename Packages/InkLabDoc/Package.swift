// swift-tools-version: 6.0
import PackageDescription

// InkLabDoc: InkLab's document core — the event-sourced "journal" the whole app sits on.
//
// The notebook is a deterministic FOLD over an ordered log of `Operation`s. Undo is appending the
// inverse op; sync/merge is a sort-union of two logs by hybrid-logical-clock; the projection is
// disposable and rebuilt by replay. See docs/decisions/0004-object-model.md.
//
// Deliberately Foundation-only (no PencilKit/CloudKit/GRDB) so the core logic is unit-tested from
// the CLI. The iOS app provides the PencilKit adapter, the GRDB local store, and the CKSyncEngine
// transport on top of these value types. Ink bytes are opaque here (BlobRef); PencilKit owns them.
//
// NOTE: the live projection uses a plain Dictionary in this prototype; production swaps it for
// apple/swift-collections `TreeDictionary` (CHAMP) for O(log N) structural sharing — a performance
// change only, the fold/merge/undo semantics proven here are identical.
let package = Package(
    name: "InkLabDoc",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "InkLabDoc", targets: ["InkLabDoc"]),
    ],
    dependencies: [
        .package(path: "../InkLabRecognition"),
    ],
    targets: [
        .target(
            name: "InkLabDoc",
            dependencies: [.product(name: "InkLabRecognition", package: "InkLabRecognition")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "InkLabDocTests",
            dependencies: ["InkLabDoc"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
