import Foundation

/// The single swappable recognition provider. The whole point of InkLab's recognition decision
/// being reversible: the compute layer depends only on `RecognitionResult`/`FormalStructure`,
/// and replacing a provider for a domain is one registration change in `RoutingRecognizer`.
///
/// Conformers: `MyScriptRecognizer` (on-device, math primary), `AppleVisionRecognizer`
/// (on-device, text), `ClaudeVisionRecognizer` (cloud via backend proxy — fallback + long-tail),
/// and `RoutingRecognizer` (the composite that picks/escalates between them).
public protocol InkRecognizer: Sendable {
    var id: ProviderID { get }
    /// True if recognition runs entirely on the device (no ink leaves the iPad).
    /// Centralizes the minors/consent decision: cloud providers (`isOnDevice == false`) only run
    /// after `CloudEligibilityPolicy` allows it.
    var isOnDevice: Bool { get }
    /// Which domain families this provider can read.
    var supportedFamilies: Set<DomainFamily> { get }

    func recognize(_ input: RecognitionInput) async throws -> RecognitionResult
}
