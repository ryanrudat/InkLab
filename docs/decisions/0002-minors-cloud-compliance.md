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
