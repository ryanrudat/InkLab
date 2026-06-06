import Foundation

/// How the current user is classified for consent purposes. Set at signup behind a neutral age
/// screen (see docs/decisions/0002-minors-cloud-compliance.md).
public enum UserKind: Sendable, Equatable {
    case adult
    /// Under the consent age, WITH verifiable parental consent on file (COPPA VPC).
    case minorConsented
    /// Under the consent age, WITHOUT verifiable parental consent.
    case minorUnconsented
    /// In a school deployment covered by a FERPA "school official" DPA.
    case schoolManaged
}

/// Session/consent state evaluated before any cloud (off-device) recognition.
public struct SessionContext: Sendable, Equatable {
    public var isOnline: Bool
    public var userKind: UserKind
    /// The App Store §5.1.2(i) (amended Nov 13 2025) explicit third-party-AI permission. Required
    /// of EVERY user before the first cloud call — a privacy-policy line is not enough.
    public var cloudAIConsentGranted: Bool

    public init(isOnline: Bool, userKind: UserKind, cloudAIConsentGranted: Bool) {
        self.isOnline = isOnline
        self.userKind = userKind
        self.cloudAIConsentGranted = cloudAIConsentGranted
    }
}

public enum CloudDecision: Sendable, Equatable {
    case allowed
    case blocked(reason: String)
}

/// Centralizes the minors/consent/offline decision so NO provider can leak ink without passing
/// the gate. Swappable for testing or for stricter policies.
public protocol CloudEligibilityPolicy: Sendable {
    func cloudEligible(_ session: SessionContext) -> CloudDecision
}

/// InkLab's shipping policy = "Policy A" (cloud + verifiable parental consent, on-device-only
/// fallback when consent is absent). Encodes the compliance decision directly:
///   - must be online,
///   - must have the §5.1.2(i) third-party-AI permission,
///   - minors require verifiable parental consent (or a school DPA).
public struct DefaultCloudPolicy: CloudEligibilityPolicy {
    public init() {}

    public func cloudEligible(_ session: SessionContext) -> CloudDecision {
        guard session.isOnline else {
            return .blocked(reason: "offline")
        }
        guard session.cloudAIConsentGranted else {
            return .blocked(reason: "third-party-AI permission not granted (App Store §5.1.2(i))")
        }
        switch session.userKind {
        case .minorUnconsented:
            return .blocked(reason: "minor without verifiable parental consent (COPPA)")
        case .adult, .minorConsented, .schoolManaged:
            return .allowed
        }
    }
}
