// swift-tools-version: 6.0
import PackageDescription

// InkLabChem: deterministic chemistry (brief §6.12). Molecular-formula parsing + molar mass, and
// chemical-equation balancing solved as exact linear algebra over the elements (the integer
// null-space of the conservation matrix) — correct by construction, never an LLM guess. SMILES /
// structure recognition is deferred to RDKit.js (not a deterministic-Swift concern). CLI-testable.
let package = Package(
    name: "InkLabChem",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "InkLabChem", targets: ["InkLabChem"])],
    targets: [
        .target(name: "InkLabChem", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "InkLabChemTests", dependencies: ["InkLabChem"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
