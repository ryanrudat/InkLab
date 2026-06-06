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
- [ ] Design for **30-day retention** as the fallback (don't assume ZDR is granted).

## Architecture
- [ ] **Server-side backend proxy** for all Claude calls (key off-device, ZDR-eligible, moderation).
- [ ] **Data minimization**: crop to the minimal ink region; strip identifiers where feasible.
- [ ] Consent state enforced server-side at the proxy, not just client-side
      (`DefaultCloudPolicy` is the client-side gate; the proxy must re-check).

> Re-verify the live wording of Apple's guidelines and Anthropic's Commercial Terms / Usage Policy /
> Trust Center at signing — they update on independent cadences.
