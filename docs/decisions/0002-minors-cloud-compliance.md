# ADR 0002 — Minors + cloud-AI compliance posture (Policy A)

**Status:** Accepted · June 2026
**Resolves:** Build brief §9 (privacy/minors) and part of §12 #4 (on-device vs server boundary)

## Context

Some users are minors (incl. under-13). MVP includes chemistry/diagrams, which have **no on-device
path** — they can only work via the cloud (Anthropic). Sending a minor's handwriting to a third-party
AI triggers App Store rules, child-privacy law, and Anthropic's own terms. Research was fact-checked
(16 confirmed / 1 refuted / 5 unsettled legal gray areas, flagged below).

## Decision: **Policy A** — cloud + verifiable parental consent, on-device-only fallback when absent.

Mapped by user kind (set behind a neutral age screen):

- **Adults** → standard consent + the §5.1.2(i) AI-disclosure prompt.
- **Minors (direct):** **verifiable parental consent (COPPA VPC)** before any cloud call; separate
  opt-in for transmission to Anthropic (treat ink→Anthropic as a "disclosure" since the law is
  unsettled).
- **Minors (school):** a **FERPA "school official" DPA** (InkLab under the school's direct control,
  education-only, no commercial use) substitutes for parental consent.
- **No valid consent / offline →** automatic on-device-only fallback; cloud-only features (chemistry/
  diagrams) degrade to an explicit "couldn't read this" — never a silent send.

These rules are encoded in `DefaultCloudPolicy` (`ConsentPolicy.swift`) with tests.

### What Apple requires (verified against the live guidelines)
- **§5.1.2(i)** (amended **Nov 13 2025**, in force, every build): clearly disclose in-app that data is
  shared with **third-party AI** and obtain **explicit permission before** the first cloud call. A
  privacy-policy line is insufficient → show an explicit prompt.
- **Ship general-audience, NOT the Kids Category.** §1.3 bars Kids-Category apps from sending PII to
  third parties (the "unless parent consents" relief is only on a non-binding marketing page); §5.1.4
  explicitly treats "drawings" as a minor's personal data; restrictions apply "even in sections
  intended for adults." (Reviewer treatment of consent-overrides-§1.3 is **uncertain** — counsel/Apple
  sign-off before any Kids-Category attempt.)
- **Always:** privacy policy naming Anthropic (equal-protection clause); App Privacy nutrition label
  (User Content = handwriting); in-app account deletion (§5.1.1(v)); signed `PrivacyInfo.xcprivacy`
  for the app **and** the MyScript SDK (hard rejection gate since May 2024); no tracking/third-party
  ads/analytics on minors. Marketing copy must avoid "for kids" framing (§2.3.8 pulls you into §1.3).

### What the law requires
- **COPPA:** under-13 high-assurance VPC ("email-plus" unavailable when disclosing to a third party);
  2025 amendments are **live** (full-compliance deadline April 22 2026 has passed) → maintain a
  written retention policy. Whether ink→Anthropic is a "disclosure" vs a service-provider relationship
  is **unsettled** → treat as a disclosure.
- **FERPA:** the school-official exception needs a DPA establishing direct control, education-only
  use, no redisclosure, school review/delete rights — passed down to Anthropic.
- **UK/EU:** don't assume "13" — EU consent age defaults to **16**; UK AADC applies (high-privacy
  defaults, DPIA).

### Anthropic feasibility (verified)
- No training on API data by default; you own outputs.
- Default **30-day** retention; **ZDR is enterprise-negotiated, not a toggle**, Messages-API only.
- 🚩 **Safety-flagged content may be retained up to 2 years even under ZDR** (classifier scores up to
  7y) — Anthropic-controlled, not deletable on request. **Hard counsel gate for minors' data.**
- "Organizations Serving Minors" policy is contractually binding and mandates **5 safeguards**: age
  verification, input/output moderation, monitoring/reporting, safety resources, AI disclosure.
  InkLab bears all COPPA/FERPA responsibility; Anthropic will **not** sign FERPA terms off-the-shelf
  (the idea it would was **refuted** — must be negotiated).

## Consequences / architecture

- **⚡ All Claude calls go through a server-side backend proxy — never client-direct** (ZDR
  eligibility, API-key security, mandated input/output moderation). InkLab needs a thin backend; see
  ADR 0003. On-device recognition + deterministic engines stay on the iPad.
- Compliance is a **pre-ship gate, not a pre-spike blocker** — the spike uses a small consented test
  corpus. Legal/contract work runs in parallel (see docs/compliance-checklist.md).
- Open counsel gates before ship: (a) Kids-Category-vs-general, (b) disclosure-vs-internal-operations
  characterization, (c) acceptability of the 2-year safety retention for minors, (d) UK/EU thresholds
  + DPIA.

## Implementation status (2026-06-07)

The architecture is **partially** in place; the consent surface this ADR mandates is **not built yet**.

- ✅ **Backend proxy is the only path to Claude.** The Server proxy enforces the consent/age gate
  independently and holds the `ANTHROPIC_API_KEY` off-device (loaded from `Server/.env`, gitignored).
  Verified live end-to-end (`/health`, `/make-real`, `/recognize`).
- 🚩 **The app sends a HARDCODED adult/consented/online session.** The real consent surface required
  by Policy A — the neutral **age screen**, the App Store **§5.1.2(i)** third-party-AI permission
  prompt, and **NWPathMonitor reachability** feeding a real `SessionContext` — is **not yet built**.
  Until it exists, the offline/no-consent fallback and the minor/adult branching cannot actually fire.
  **This is required before any cloud use by minors.**
- ⏳ **Deferred (unchanged):** real input/output moderation (Organizations-Serving-Minors), and
  ZDR / data minimization remain TODO on the server.

## Implementation status (2026-06-08)

The consent gate and proxy boundary are in place; the make-real sandbox was hardened and on-device
data now persists. The first-run consent UI and persisting the consent choice are still TODO.

- ✅ **Two-sided consent gate.** The client sends a `Session` (`MakeReal.swift`) whose `blockReason`
  blocks the request when ineligible; the server independently re-checks it via `cloudEligible`
  (`Server/src/consent.ts`) — the client value is advisory, the server is the truth. Both mirror the
  Swift `DefaultCloudPolicy` (`ConsentPolicy.swift`). The API key stays off-device in `Server/.env`.
- ✅ **Make-real widget sandbox hardened (ties into ADR 0005).** `WebWidgetView`'s CSP now allows
  `script-src 'unsafe-eval'` (alongside `'unsafe-inline'`) so generated graphers/calculators can
  evaluate a user-typed expression; previously a CSP "refused to evaluate a string as JavaScript"
  error broke them. **Justified because eval is not the security boundary — NETWORK ISOLATION is:**
  `default-src 'none'` (no fetch/XHR/external scripts/styles/frames) + `baseURL nil` + a navigation
  delegate that cancels every navigation after the initial in-memory load + the server-side validator
  (`Server/src/validate.ts`) rejecting external script/stylesheet srcs, `fetch`/XMLHttpRequest, and
  iframes. With no path to the network or out of the card, `eval` can only compute locally. CSP is
  injected at render time so already-generated widgets are covered too.
- ✅ **On-device data persists with FileProtection.** The op-log journal + per-page ink blobs persist
  under Application Support per notebook (`JournalStorage.swift`), written with
  `FileProtectionType.completeUntilFirstUserAuthentication` and fsync'd. This keeps a minor's ink
  on-device by default; nothing leaves the iPad without passing the consent gate above.
- 🚩 **Railway is interim hosting.** The proxy runs on Railway for now; **data-residency for minors
  and ZDR must be revisited before publication** (see ADR 0003).
- 🚩 **Still TODO (required before cloud use by minors):** the §5.1.2(i) first-run **age-gate /
  consent UI**, and **persisting the consent choice** — `AppSettings` consent (cloud-AI opt-in +
  userKind/ageVerified) is still in-memory and **resets each launch**; only the notebook list and the
  journal/ink persist, not the consent settings.

## Implementation status (2026-06-09)

The server consent gate was hardened from **fail-OPEN to fail-CLOSED** — closing a hole where a
misclassified or tampered minor's ink could have reached Anthropic.

- ✅ **`cloudEligible` is now a fail-CLOSED whitelist (`Server/src/consent.ts`).** Previously it only
  blocked the literal `userKind === 'minorUnconsented'`; because the session is untrusted JSON
  validated nowhere, any typo'd / tampered / missing / unknown `userKind` fell through to **allowed**
  — so a minor's ink could reach Anthropic. It now **validates the session shape at runtime** and
  **whitelists only known-eligible kinds** (adult / minorConsented / schoolManaged, each requiring
  `ageVerified`), defaulting to **BLOCKED**. New tests cover the rejected/unknown cases.
- 🚩 **Swift `DefaultCloudPolicy` still omits the `ageVerified` safeguard** (`ConsentPolicy.swift`).
  LOW / dead-code today — the app gates via `MakeRealSession.blockReason`, which *does* check it.
  Align `DefaultCloudPolicy` before `RoutingRecognizer` is ever wired for minors.
- ✅ **Proxy stops leaking internals (defense-in-depth).** Errors are now generic (`500 "internal
  error"` / `502 "upstream error"`); the verbatim upstream Anthropic error body (incl. `request_id`)
  is no longer propagated. Added an 8 MB request body-size cap (`413`) and a `400` on malformed/missing
  JSON (was a `500`).
- ⏳ **Still TODO (unchanged):** real input/output **moderation** (Organizations-Serving-Minors), and
  the §5.1.2(i) first-run **age-gate / consent UI** with a persisted consent choice.
- ↪ **Backup/sync keeps data out of our custody (2026-06-17, [ADR 0006](0006-backup-and-sync.md)).**
  Notebook backup is **serverless** — a Files/iCloud-Drive export, then CloudKit in the user's *own*
  iCloud — so InkLab never becomes a custodian of minors' handwriting, preserving this Policy A
  data-minimization posture. Notebooks must **not** be stored on our proxy.

## Implementation status (2026-06-25)

A consent surface now exists — in **Settings**, not yet as a first-run gate — and the client now sends
`ageVerified` on the wire, narrowing (but not closing) the §5.1.2(i) consent-UI gap above.

- ✅ **Consent UI in Settings (`SettingsView.swift`).** An "Allow AI generation" toggle
  (`cloudAIConsentGranted`, OFF by default), a `userKind` picker, and an "Age verified" toggle for
  minors are wired to `AppSettings` (`Library.swift`). `AppSettings.makeRealSession` builds the
  `MakeRealSession` sent with each "@" request (`ageVerified` forced `true` for adults, taken from the
  toggle otherwise); `MakeRealSession.blockReason` (`MakeReal.swift`) enforces the gate client-side and
  the server re-checks via `cloudEligible`. This supersedes the earlier "consent surface … is not built
  yet" note — for the Settings path.
- 🚩 **Still NOT a first-run §5.1.2(i) age-gate.** Consent lives only in Settings; there is no neutral
  first-run age screen / explicit pre-first-call permission prompt, and **no NWPathMonitor
  reachability** (`makeRealSession.isOnline` is hardcoded `true`). Required before any cloud use by
  minors.
- 🚩 **Consent choice still does NOT persist (unchanged).** `cloudAIConsentGranted`, `userKind`, and
  `ageVerified` on `AppSettings` have no `UserDefaults` load/`didSet` (unlike `defaultPaper` /
  `snapShapesOnHold`) — they **reset to not-consented each launch**. Persist before relying on the gate.
- 🚩 **Swift `DefaultCloudPolicy` still omits `ageVerified` (unchanged, `ConsentPolicy.swift`).** Dead
  today — the app gates via `MakeRealSession.blockReason`, which *does* check it; align before
  `DefaultCloudPolicy` is ever wired for minors.
- ⏳ **Still TODO (unchanged):** real input/output **moderation** (Organizations-Serving-Minors), and
  ZDR / data-residency for minors (Railway is interim — see [ADR 0003](0003-ipados-floor-and-backend-proxy.md)).
