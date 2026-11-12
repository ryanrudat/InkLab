# Compliance checklist (pre-ship gate, not pre-spike)

Tracks the work to ship the cloud path for minors under **Policy A** (ADR 0002). None of this blocks
the recognition spike (which uses a small consented test corpus); it runs in parallel toward ship.
Items marked 🔴 require legal counsel.

## App Store
- [ ] In-app **§5.1.2(i) disclosure + explicit permission prompt** before the first Anthropic call
      (every user; not just a privacy-policy line).
- [ ] Ship **general-audience**, not Kids Category. 🔴 Counsel/Apple sign-off if Kids Category is ever
      considered (§1.3 vs the marketing-page consent allowance is unresolved).
- [ ] Privacy policy (in-app + App Store Connect) naming **Anthropic** as recipient + equal-protection
      clause + retention/deletion + how to revoke consent.
- [ ] App Privacy **nutrition label**: User Content (handwriting), any Identifiers/Usage Data; same
      standard for children.
- [ ] In-app **account deletion** (§5.1.1(v)) — deletes the whole account + data.
- [ ] Signed **`PrivacyInfo.xcprivacy`** for the app AND the MyScript SDK.
- [ ] No tracking / third-party ads / analytics on minors. Marketing copy avoids "for kids" (§2.3.8).

## Law
- [ ] **COPPA VPC** flow for under-13 (high-assurance method; not "email-plus"). 🔴
- [ ] Treat ink→Anthropic as a **disclosure** → separate opt-in. 🔴 (characterization unsettled)
- [ ] Written **data-retention policy** (2025 COPPA amendments, live).
- [ ] **FERPA school-official DPA** for school deployments (direct control, education-only, no
      redisclosure, review/delete) — passed down to Anthropic. 🔴
- [ ] **UK/EU** age thresholds (EU default 16) + UK AADC high-privacy defaults + **DPIA**. 🔴

## Anthropic
- [ ] Sign Commercial Terms + DPA. Engage sales to: request negotiated **ZDR**; get written terms on
      the **2-year safety-flag retention** as applied to minors 🔴; ask about FERPA school-official
      language for the school SKU.
- [ ] Implement the **5 "Organizations Serving Minors" safeguards**: age verification, input/output
      moderation, monitoring/reporting, safety resources, AI disclosure.
      🔴 **Gate for the Socratic tutor (`POST /tutor`, 2026-11-12):** it is an open-ended chat with the
      student, so **input/output moderation must be done before any minor uses it** — not only before
      ship. The tutor's answer-leak guard and "stay on the math problem" prompt are **not** moderation.
- [ ] Design for **30-day retention** as the fallback (don't assume ZDR is granted).

## OpenAI (widget generation, added 2026-11-12)
`/make-real` now defaults to OpenAI's `gpt-6.1-sol` when `OPENAI_API_KEY` is set (Claude is the fallback,
and handwriting recognition stays on Claude). OpenAI receives the student's **prompt text** (not ink), so it
is a second third-party AI recipient. 🔴 **Before any minor uses widget generation through OpenAI:**
- [ ] Review OpenAI's business terms, DPA and usage policies as they apply to **minors / education**;
      confirm whether **zero data retention** is available and what the default retention is.
- [ ] Data residency / region for minors' prompts; record the decision alongside ADR 0002.
- [ ] Privacy policy + App Store disclosure name **OpenAI** as a recipient (the in-app consent text in
      `SettingsView` was updated to say widgets go to OpenAI and handwriting to Anthropic).
- [ ] Input/output **moderation** covers the OpenAI path too (the same "Organizations Serving Minors" bar).
- [ ] ADR 0002 / ADR 0003 updated to name both providers (they currently assume Anthropic only).

## Architecture
- [ ] **Server-side backend proxy** for all Claude calls (key off-device, ZDR-eligible, moderation).
- [ ] **Data minimization**: crop to the minimal ink region; strip identifiers where feasible.
- [ ] Consent state enforced server-side at the proxy, not just client-side
      (`DefaultCloudPolicy` is the client-side gate; the proxy must re-check).

> Re-verify the live wording of Apple's guidelines and Anthropic's Commercial Terms / Usage Policy /
> Trust Center at signing — they update on independent cadences.

---

## Status (2026-06-08)

Compliance remains **PRE-SHIP** and largely **outstanding** — the checklist above is unchanged and
still current. The cloud path now works end-to-end in development, which raises the stakes on the gaps.

**What exists today**
- **Backend proxy** holds the Anthropic key off-device (Server reads `ANTHROPIC_API_KEY` from
  `Server/.env`, which is **gitignored**) and enforces a **consent/age gate** on the cloud endpoints.
- **Student data now persists on-device** (as of 2026-06-08): the op-log journal (JSONL) + per-page
  PKDrawing ink blobs are written under Application Support per notebook (`FileJournalStorage`), and
  the notebook list persists (`library.json`). All of it is written with locked-device file protection
  (`FileProtectionType.completeUntilFirstUserAuthentication`) and `fsync` on flush — so handwriting
  stays **at rest, on-device, encrypted while the device is locked**, and never leaves the device on
  the deterministic engines / native-widget paths. (CloudKit sync is **not** built; if/when it lands it
  is a new data-flow that re-opens the data-residency-for-minors question below.)
- **Generated-widget sandbox** (the make-real WebViews): the CSP now allows `script-src 'unsafe-eval'`
  alongside `'unsafe-inline'` so graphers/calculators can evaluate a user-typed expression. **This is
  not a sandbox regression.** The safety boundary was never the JS-eval restriction — it is **network
  isolation**: `default-src 'none'` (+ no `connect-src`/`img-src`-to-network), `baseURL` nil, a
  navigation delegate that cancels navigation, and the server-side validator that blocks
  external/`fetch`/`<iframe>` content. A widget can evaluate a typed expression but **cannot reach the
  network or escape its card**, so no student data can be exfiltrated from a widget.

**Still needed before any minor uses the cloud path (unchanged, just current)**
- **Consent settings are still in-memory and reset every launch.** Only the notebook list +
  journal/ink persist; the cloud-AI opt-in / `userKind` / `ageVerified` (`AppSettings`) do **not** —
  persisting consent state durably (and enforcing it server-side at the proxy) is still TODO.
- **Verifiable parental-consent flow** (COPPA VPC) — not yet built.
- **In-app §5.1.2(i) AI-disclosure / permission prompt** — the app currently sends a **hardcoded
  adult/consented/online session**; there is no real age screen, permission prompt, or reachability.
- **Input/output moderation** (the "Organizations Serving Minors" safeguards).
- **ZDR + written data-retention policy.**
- **App Privacy labels + signed `PrivacyInfo.xcprivacy`.**
- **In-app account deletion.**
- **Hosting is interim (Railway).** Revisit before publication — **data residency for minors** and
  **ZDR** are not settled on Railway; the proxy host must be confirmed against the COPPA/FERPA posture.
- **Legal counsel sign-off** on the items marked 🔴.

---

## Status (2026-06-09)

Compliance remains **PRE-SHIP** and largely **outstanding** — the checklist above and the 2026-06-08
status are unchanged. One architectural item was meaningfully strengthened this session.

**Hardened this session**
- **Consent gate is now FAIL-CLOSED at the proxy** (was fail-open). `Server/src/consent.ts`
  `cloudEligible` previously blocked only the literal `userKind === 'minorUnconsented'`; any
  typo'd / tampered / missing / unknown `userKind` (the session is untrusted JSON, validated nowhere)
  fell through to **allowed** — so a minor's ink could reach Anthropic. It now validates the session
  **shape** at runtime and **whitelists only known-eligible kinds** (`adult` / `minorConsented` /
  `schoolManaged`, with `ageVerified`), **defaulting to BLOCKED**. This is a real strengthening of
  "consent enforced server-side at the proxy." New tests. (Note: the Swift `DefaultCloudPolicy` still
  omits the `ageVerified` safeguard — LOW / dead-code today, since the app gates via
  `MakeRealSession.blockReason` which does check it — but align it if `RoutingRecognizer` is ever
  wired for minors.)
- **Proxy no longer leaks internals**: errors are now generic (500 "internal error" / 502 "upstream
  error") and `anthropic.ts` no longer embeds the verbatim upstream Anthropic error body
  (incl. `request_id`) in propagated errors. Added a **request body-size cap** (8 MB → 413), a **400**
  on malformed/missing JSON (was a 500), and broadened `validateWidgetHtml` (defense-in-depth; the
  on-device WKWebView CSP remains the real boundary).

**Still outstanding (unchanged)**
- First-run **§5.1.2(i) AI-disclosure / permission prompt** and **persisting consent state** durably.
- **Verifiable parental-consent flow** (COPPA VPC).
- **Input/output moderation** ("Organizations Serving Minors" safeguards).
- **ZDR + written data-retention policy.**
- **App Privacy labels + signed `PrivacyInfo.xcprivacy`.**
- **In-app account deletion.**
- **Legal counsel sign-off** on the items marked 🔴.

---

## Status (2026-06-17) — backup/sync decision keeps data OUT of our custody

A user lost notebooks by deleting the (dev-installed) app — there is **no backup today**, so a backup
path is needed. The chosen architecture (**ADR 0006**) is **compliance-preserving by design**:
- **Backup/sync stays serverless.** A **Files / iCloud-Drive export** ships first, then **CloudKit**
  (the user's own private iCloud database). Neither puts notebook content on infrastructure we operate,
  so **InkLab never becomes a custodian of user (incl. minors') handwriting** — preserving the on-device
  posture above and avoiding new COPPA/FERPA retention/deletion/breach obligations.
- **The Railway proxy must stay STATELESS** (forwards prompts to Claude; stores nothing). Storing
  notebooks on it would directly contradict the §"Architecture" data-minimization items and the
  data-residency-for-minors gate. Explicitly out of scope for the proxy.
- **On import / cross-device sync, re-validate generated widget HTML** before loading (untrusted-origin
  rule) — tracked with the make-real sandbox boundary.

Account-deletion (§5.1.1(v)) should, once accounts exist, also delete the CloudKit zone + any exports.
Otherwise the checklist above is unchanged and still PRE-SHIP.

---

## Status (2026-06-25) — consent is now driven by a real Settings UI (but still doesn't persist)

Compliance remains **PRE-SHIP** and largely **outstanding**. The checklist above and all prior status
sections are unchanged. One client-side gap from 2026-06-08 has been partially closed; the rest stand.

**Changed this session — the "hardcoded adult/consented session" is gone**
- The make-real session is now **wired to a real Settings screen**, not a hardcoded
  `adult/consented/online` literal. `AppSettings` (in `Library.swift`) holds `cloudAIConsentGranted`
  (**OFF by default**), `userKind` (`adult` / `minorConsented` / `minorUnconsented` / `schoolManaged`),
  and `ageVerified`; it builds `makeRealSession`, and `CanvasScreen` mirrors it into the canvas model
  (live, via `onChange`) so a real user's state — not a constant — gates every generation. `SettingsView`
  exposes the user-kind picker, an age-verified toggle (shown for non-adults), and an explicit
  "Allow AI generation" opt-in carrying the §5.1.2(i) wording. With the toggle off, `blockReason`
  short-circuits the "@" path before any network call. **This makes the on-device gate real**, on top
  of the fail-closed server-side re-check (`Server/src/consent.ts`, which validates session shape and
  whitelists only `adult` / `minorConsented` / `schoolManaged` with `ageVerified`).
- The previous 2026-06-08 line — *"the app currently sends a hardcoded adult/consented/online session;
  there is no real age screen, permission prompt"* — is now **stale** and superseded by the above.

**Still missing on the client (the gap narrowed, it did not close)**
- **Consent state still does NOT persist.** `cloudAIConsentGranted`, `userKind`, and `ageVerified` have
  **no `didSet`/UserDefaults backing** and **reset to defaults every launch** (adult / not consented /
  not age-verified). Only `defaultPaper` and `snapShapesOnHold` persist. Durable consent persistence is
  still TODO. (Net effect today is fail-safe — it resets to *unconsented* — but it is not the required
  durable record.)
- **No first-run §5.1.2(i) disclosure / permission prompt.** Consent lives in Settings, opt-in and off
  by default, but there is **no forced first-launch disclosure or neutral age screen** before the first
  cloud call — the user must find the toggle. No onboarding/consent sheet exists in the app entry point.

**Still outstanding (unchanged — verified absent this session)**
- **Verifiable parental-consent flow** (COPPA VPC) — not built.
- **Input/output moderation** ("Organizations Serving Minors" safeguards) — no moderation in `Server/src`.
- **ZDR + written data-retention policy.**
- **App Privacy labels + signed `PrivacyInfo.xcprivacy`** — no `.xcprivacy` file exists in the repo.
- **In-app account deletion** (§5.1.1(v)) — only per-notebook delete exists, not account/data wipe.
- **Files/iCloud-Drive export + CloudKit backup** (ADR 0006) — not yet built; storage is still the
  on-device file journal (CloudKit noted as "later" behind the storage protocol).
- **Hosting is still interim (Railway).** Config present (`railway.json`, `.nvmrc`, `.railwayignore`);
  data-residency-for-minors / ZDR not settled on Railway. Revisit before publication.
- **Legal counsel sign-off** on the items marked 🔴.

> Note: the floating-dock rewrite this session (global-coordinate drag, side-wall snap-to-vertical) is
> a UI-layout change only and has **no compliance surface** — it touches no data flow, network, or
> consent path.

> The repo is now a **public GitHub repo** (`https://github.com/ryanrudat/InkLab`). The Anthropic key
> stays off-device in the proxy and `Server/.env` is gitignored; confirm no secrets are committed before
> each push (the key, signed DPAs, and any consent records must never enter the public history).

## Status (2026-11-12) — the Socratic tutor adds a chat with the student

The new tutor (`Server/src/tutor.ts`, app `Tutor.swift`) is the first feature where a student **converses**
with Claude, so the minors' safeguards bite harder here than for `@` widgets or recognition:

- **🔴 Moderation must ship first.** A minor must not use the tutor until **input/output moderation** (the
  "Organizations Serving Minors" safeguard) is in place on the proxy, plus monitoring/reporting and safety
  resources for anything a student writes that isn't about the math. Until then the tutor is for
  adult testing only. What exists today is *not* moderation: the system prompt keeps the model on the
  problem and tells it to ignore instructions inside the student's text, and a deterministic guard stops
  it from giving away answers.
- **What is sent:** the transcribed working, the red pen's verdict, the thread so far (the student's
  replies, typed or read from handwriting near the problem) — text only, no ink image after the initial
  read. The proxy stores nothing (stateless); the thread lives in the notebook's journal on the device.
- **Gate:** the same `cloudEligible` whitelist runs first on every `/tutor` call (403 before any model
  call), and the app's `tutorBlockReason` refuses up front. Ink written next to an active tutor session is
  read through the consent-gated recognizer only while that session's messages are on the page.
- **Disclosure:** the AI-permission copy in Settings still talks about "@" prompts only. It must also say
  that the tutor sends the student's working and replies to Anthropic before this ships.
