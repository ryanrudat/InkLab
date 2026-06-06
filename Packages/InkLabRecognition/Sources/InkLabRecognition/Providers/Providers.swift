import Foundation

// Concrete provider stubs marking the integration points. They conform to `InkRecognizer` and
// advertise their real capabilities/origin, but `recognize` throws `.notImplemented` until wired
// to the respective SDK/service. The routing logic is fully exercised by the tests using
// configurable test doubles, so these can be filled in independently during the spike.

/// On-device, math-first primary. Bridge `input.strokes` -> MyScript iink pointer events; map the
/// JIIX expression tree / LaTeX / MathML output -> `FormalStructure`. Runs offline after a one-time
/// license activation. See docs/recognition-spike-plan.md.
public struct MyScriptRecognizer: InkRecognizer {
    public let id: ProviderID = .myscript
    public let isOnDevice: Bool = true
    public let supportedFamilies: Set<DomainFamily> = [.math, .text, .diagram]
    public init() {}
    public func recognize(_ input: RecognitionInput) async throws -> RecognitionResult {
        throw RecognitionError.notImplemented(.myscript)
    }
}

/// On-device text OCR via Apple Vision (rasterized strokes -> `VNRecognizeTextRequest`). Text only
/// — flat strings, which is all notes/search need. No math/chemistry structure.
public struct AppleVisionRecognizer: InkRecognizer {
    public let id: ProviderID = .appleVision
    public let isOnDevice: Bool = true
    public let supportedFamilies: Set<DomainFamily> = [.text]
    public init() {}
    public func recognize(_ input: RecognitionInput) async throws -> RecognitionResult {
        throw RecognitionError.notImplemented(.appleVision)
    }
}

/// Cloud fallback + long-tail (chemistry/diagrams), via InkLab's server-side backend proxy
/// (never client-direct — required for ZDR eligibility, key security, and input/output moderation;
/// see docs/decisions/0002-minors-cloud-compliance.md). Output is always validated before use.
public struct ClaudeVisionRecognizer: InkRecognizer {
    public let id: ProviderID = .claudeVision
    public let isOnDevice: Bool = false
    public let supportedFamilies: Set<DomainFamily> = [.math, .text, .chemistry, .diagram]
    public init() {}
    public func recognize(_ input: RecognitionInput) async throws -> RecognitionResult {
        throw RecognitionError.notImplemented(.claudeVision)
    }
}

/// A convenience builder wiring InkLab's default stack: MyScript (on-device math/text/diagram),
/// Apple Vision (on-device text, preferred over MyScript for plain text), Claude (cloud fallback +
/// chemistry/diagram long-tail). Swap a single map entry to change a provider for a domain.
public enum DefaultRecognizerStack {
    public static func make(confidenceThreshold: Double = 0.8) -> RoutingRecognizer {
        let registry: [ProviderID: any InkRecognizer] = [
            .myscript: MyScriptRecognizer(),
            .appleVision: AppleVisionRecognizer(),
            .claudeVision: ClaudeVisionRecognizer(),
        ]
        return RoutingRecognizer(
            registry: registry,
            onDeviceByFamily: [
                .math: .myscript,
                .text: .appleVision,
                .diagram: .myscript,   // generic shapes only; cloud handles semantic diagrams
            ],
            cloudByFamily: [
                .math: .claudeVision,
                .text: .claudeVision,
                .chemistry: .claudeVision,
                .diagram: .claudeVision,
            ],
            confidenceThreshold: confidenceThreshold
        )
    }
}
