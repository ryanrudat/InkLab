// swift-tools-version: 6.0
import PackageDescription

// InkLabBio: deterministic biology (brief §6.13). DNA→mRNA transcription, translation via the
// standard genetic code, point-mutation classification, and Punnett squares — all exact and
// table-driven (no LLM guess). 3D biomolecule structure (PDB viewer) is deferred. CLI-testable.
let package = Package(
    name: "InkLabBio",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "InkLabBio", targets: ["InkLabBio"])],
    targets: [
        .target(name: "InkLabBio", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "InkLabBioTests", dependencies: ["InkLabBio"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
