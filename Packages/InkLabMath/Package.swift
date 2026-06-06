// swift-tools-version: 6.0
import PackageDescription

// InkLabMath: the deterministic algebra core behind the "red-pen tutor".
//
// Correctness by construction: handwritten steps are parsed into an AST, normalized to an EXACT
// canonical form (rational functions over multivariate polynomials with rational coefficients), and
// consecutive steps are checked for true mathematical equivalence — never an LLM guess. The model
// only READS ink into a formal structure; this engine COMPUTES the verdict (brief §4.1, §6.4).
//
// Foundation-only, fully CLI-testable. The iOS app feeds it the recognizer's output (LaTeX /
// expression tree) and renders the verdict in place next to the student's working.
let package = Package(
    name: "InkLabMath",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "InkLabMath", targets: ["InkLabMath"]),
    ],
    targets: [
        .target(name: "InkLabMath", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "InkLabMathTests", dependencies: ["InkLabMath"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
