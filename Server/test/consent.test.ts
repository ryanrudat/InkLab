import { test } from 'node:test'
import assert from 'node:assert/strict'
import { cloudEligible } from '../src/consent.ts'
import type { Session } from '../src/types.ts'

const base: Session = { isOnline: true, userKind: 'adult', aiConsentGranted: true, ageVerified: true }

test('adult online with consent is allowed', () => {
  assert.deepEqual(cloudEligible(base), { allowed: true })
})

test('offline is blocked', () => {
  const d = cloudEligible({ ...base, isOnline: false })
  assert.equal(d.allowed, false)
})

test('missing third-party-AI permission is blocked (§5.1.2(i))', () => {
  const d = cloudEligible({ ...base, aiConsentGranted: false })
  assert.equal(d.allowed, false)
})

test('minor without parental consent is blocked (COPPA)', () => {
  const d = cloudEligible({ ...base, userKind: 'minorUnconsented' })
  assert.equal(d.allowed, false)
})

test('consented minor must be age-verified', () => {
  assert.equal(cloudEligible({ ...base, userKind: 'minorConsented', ageVerified: false }).allowed, false)
  assert.equal(cloudEligible({ ...base, userKind: 'minorConsented', ageVerified: true }).allowed, true)
})

test('school-managed minor (age-verified) is allowed', () => {
  assert.equal(cloudEligible({ ...base, userKind: 'schoolManaged' }).allowed, true)
})

// --- fail-closed: untrusted session shape (the gate is a whitelist, not a blacklist) ---

test('unknown/typo userKind is BLOCKED, not allowed (no fall-through)', () => {
  // The old blacklist allowed anything except the literal 'minorUnconsented' — a misclassified or
  // tampered minor would have passed. The whitelist must block it.
  assert.equal(cloudEligible({ ...base, userKind: 'kid' as any }).allowed, false)
  assert.equal(cloudEligible({ ...base, userKind: 'MINORUNCONSENTED' as any }).allowed, false)
})

test('missing or malformed session is blocked', () => {
  assert.equal(cloudEligible(undefined).allowed, false)
  assert.equal(cloudEligible(null).allowed, false)
  assert.equal(cloudEligible({}).allowed, false)
  assert.equal(cloudEligible({ ...base, userKind: undefined as any }).allowed, false)
  assert.equal(cloudEligible({ ...base, isOnline: 'yes' as any }).allowed, false)
  assert.equal(cloudEligible({ ...base, ageVerified: undefined as any }).allowed, false)
})
