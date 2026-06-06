import Foundation

/// The composite recognizer that encodes InkLab's recognition decision as executable rules:
///
///   1. Try the on-device provider for the domain first (privacy + latency + offline).
///   2. Accept it iff confidence >= threshold AND it passes the deterministic validator.
///   3. Otherwise consider the cloud provider — but ONLY if `CloudEligibilityPolicy` allows it
///      (online + consent + not an unconsented minor).
///   4. Cloud output is accepted ONLY if it passes the validator; a cloud parse failure falls back
///      to the best on-device read, never to an unvalidated cloud guess.
///   5. If a domain is cloud-only (e.g. chemistry/diagrams) and cloud is blocked, return
///      `.unrecognized` with a reason — explicit and silent, never a silent cloud send.
///
/// Swapping which provider serves a family (e.g. MyScript -> Claude for `.math` if the spike fails)
/// is a one-line change to `onDeviceByFamily` / `cloudByFamily`.
public struct RoutingRecognizer: InkRecognizer {
    public let id: ProviderID = .routing
    public let isOnDevice: Bool = false  // composite; the chosen result reports its own origin

    private let registry: [ProviderID: any InkRecognizer]
    private let onDeviceByFamily: [DomainFamily: ProviderID]
    private let cloudByFamily: [DomainFamily: ProviderID]
    private let consentPolicy: any CloudEligibilityPolicy
    private let validator: any FormalStructureValidator
    private let confidenceThreshold: Double

    public init(registry: [ProviderID: any InkRecognizer],
                onDeviceByFamily: [DomainFamily: ProviderID],
                cloudByFamily: [DomainFamily: ProviderID],
                consentPolicy: any CloudEligibilityPolicy = DefaultCloudPolicy(),
                validator: any FormalStructureValidator = DefaultFormalStructureValidator(),
                confidenceThreshold: Double = 0.8) {
        self.registry = registry
        self.onDeviceByFamily = onDeviceByFamily
        self.cloudByFamily = cloudByFamily
        self.consentPolicy = consentPolicy
        self.validator = validator
        self.confidenceThreshold = confidenceThreshold
    }

    public var supportedFamilies: Set<DomainFamily> {
        Set(onDeviceByFamily.keys).union(cloudByFamily.keys)
    }

    public func recognize(_ input: RecognitionInput) async throws -> RecognitionResult {
        let family = input.domainHint.family
        var alternatives: [Candidate] = []
        var onDevicePrimary: RecognitionResult?

        // 1–2. On-device first.
        if let odID = onDeviceByFamily[family], let onDevice = registry[odID] {
            let r = try await onDevice.recognize(input)
            alternatives.append(Candidate(formal: r.formal, readAs: r.readAs, confidence: r.confidence))
            alternatives.append(contentsOf: r.alternatives)
            if r.confidence >= confidenceThreshold && validator.validate(r.formal, family: family) {
                return merged(base: r, alternatives: alternatives)
            }
            onDevicePrimary = r  // keep as fallback if cloud is unavailable/unusable
        }

        // 3–4. Cloud escalation, gated.
        if let cloudID = cloudByFamily[family], let cloud = registry[cloudID] {
            switch consentPolicy.cloudEligible(input.session) {
            case .allowed:
                if let cr = try? await cloud.recognize(input) {
                    if validator.validate(cr.formal, family: family) {
                        var alts = alternatives
                        alts.append(Candidate(formal: cr.formal, readAs: cr.readAs, confidence: cr.confidence))
                        alts.append(contentsOf: cr.alternatives)
                        return merged(base: cr, alternatives: alts)
                    } else {
                        // Cloud produced something that failed the deterministic parse: keep it only
                        // as a non-authoritative alternative, never as the accepted result.
                        alternatives.append(Candidate(formal: cr.formal, readAs: cr.readAs, confidence: cr.confidence))
                    }
                }
            case .blocked(let reason):
                if let primary = onDevicePrimary {
                    return merged(base: primary, alternatives: alternatives,
                                  note: "cloud unavailable (\(reason)); returned best on-device read")
                }
                return unrecognized(family: family,
                                    reason: "requires cloud but \(reason)",
                                    alternatives: alternatives)
            }
        }

        // 5. Fall back to the best on-device read, or an explicit unrecognized.
        if let primary = onDevicePrimary {
            return merged(base: primary, alternatives: alternatives)
        }
        return unrecognized(family: family,
                            reason: "no recognizer registered for \(family.rawValue)",
                            alternatives: alternatives)
    }

    // MARK: - Helpers

    /// Builds the final result: the chosen read plus de-duplicated, confidence-ranked alternatives
    /// (the chosen read removed from the alternatives list).
    private func merged(base: RecognitionResult, alternatives: [Candidate], note: String? = nil) -> RecognitionResult {
        var seen = Set<String>([base.readAs])
        let ranked = alternatives
            .filter { $0.readAs != base.readAs && seen.insert($0.readAs).inserted }
            .sorted { $0.confidence > $1.confidence }
        return RecognitionResult(
            formal: base.formal,
            confidence: base.confidence,
            readAs: base.readAs,
            alternatives: ranked,
            provider: base.provider,
            isOnDevice: base.isOnDevice,
            latency: base.latency,
            note: note ?? base.note
        )
    }

    private func unrecognized(family: DomainFamily, reason: String, alternatives: [Candidate]) -> RecognitionResult {
        RecognitionResult(
            formal: .unrecognized(reason: reason),
            confidence: 0,
            readAs: "",
            alternatives: alternatives.sorted { $0.confidence > $1.confidence },
            provider: .routing,
            isOnDevice: false,
            latency: .zero,
            note: reason
        )
    }
}
