import type { Session, CloudDecision, UserKind } from './types.ts'

const ALL_KINDS: ReadonlySet<string> = new Set<UserKind>(['adult', 'minorConsented', 'minorUnconsented', 'schoolManaged'])
const ELIGIBLE_KINDS: ReadonlySet<string> = new Set<UserKind>(['adult', 'minorConsented', 'schoolManaged'])

/// Server-side enforcement of the cloud-eligibility policy (mirrors the Swift DefaultCloudPolicy and
/// ADR 0002 "Policy A"). The proxy NEVER calls Anthropic for an ineligible session, even if the
/// client failed to gate it — defence in depth for minors' data.
///
/// This is a WHITELIST that FAILS CLOSED: the session arrives as untrusted JSON from the client, the
/// TypeScript `Session` type is erased at runtime, so we validate the SHAPE here and only return
/// `allowed` for a positively-recognized eligible kind. A missing/typo'd/tampered/future `userKind`
/// (or a non-boolean flag) is BLOCKED — never allowed to fall through. (Previously this was a blacklist
/// that allowed anything except the literal 'minorUnconsented', which let a misclassified minor's ink
/// reach Anthropic.)
export function cloudEligible(session: unknown): CloudDecision {
  const s = session as Partial<Session> | null | undefined
  if (!s || typeof s !== 'object') return { allowed: false, reason: 'invalid session' }
  if (
    typeof s.isOnline !== 'boolean' ||
    typeof s.aiConsentGranted !== 'boolean' ||
    typeof s.ageVerified !== 'boolean' ||
    typeof s.userKind !== 'string' ||
    !ALL_KINDS.has(s.userKind)
  ) {
    return { allowed: false, reason: 'invalid session' }
  }
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
  // Final fail-closed guard: only positively-eligible kinds may be allowed.
  if (!ELIGIBLE_KINDS.has(s.userKind)) return { allowed: false, reason: 'ineligible session' }
  return { allowed: true }
}
