import type { Session, CloudDecision } from './types.ts'

/// Server-side enforcement of the cloud-eligibility policy (mirrors the Swift DefaultCloudPolicy and
/// ADR 0002 "Policy A"). The proxy NEVER calls Anthropic for an ineligible session, even if the
/// client failed to gate it — defence in depth for minors' data.
export function cloudEligible(s: Session): CloudDecision {
  if (!s.isOnline) return { allowed: false, reason: 'offline' }
  if (!s.aiConsentGranted) {
    return { allowed: false, reason: 'third-party-AI permission not granted (App Store §5.1.2(i))' }
  }
  if (s.userKind === 'minorUnconsented') {
    return { allowed: false, reason: 'minor without verifiable parental consent (COPPA)' }
  }
  if ((s.userKind === 'minorConsented' || s.userKind === 'schoolManaged') && !s.ageVerified) {
    return { allowed: false, reason: 'age not verified (Organizations Serving Minors safeguard)' }
  }
  return { allowed: true }
}
