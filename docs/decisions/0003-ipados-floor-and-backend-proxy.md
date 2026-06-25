# ADR 0003 — iPadOS floor + the backend proxy

**Status:** Accepted · June 2026
**Resolves:** Build brief §12 #4 (on-device vs server boundary) and the deployment-target choice

## iPadOS floor: **iPadOS 18**

"iPadOS version" (software) and "device age" (hardware) are different axes — a chip gets 6–7 years of
OS updates, so the gate that matters for recognition performance is the **chip / Neural Engine**, not
the calendar.

- **iPadOS 18 captures ~83% of active iPads** (Apple App Store data, Feb 12 2026: ~57% on iPadOS 26 +
  ~26% on iPadOS 18; the sub-splits are third-party readings of Apple's chart, treat with mild
  caution; managed school fleets may skew older).
- Every iPadOS-18 device **except the lone iPad 7th-gen (A10, no Neural Engine)** has a Neural Engine.
- **Decision:** floor = iPadOS 18, and **gate on-device ML behind an actual Neural-Engine capability
  check** — route the A10 iPad 7th-gen to CPU/GPU or the cloud path rather than assuming a NE exists.
- Alternative: iPadOS 26 (A12+) guarantees a Neural Engine on 100% of devices and simplifies code, at
  ~17% reach cost — revisit if on-device ML/Pencil performance outweighs older-fleet reach. **Do not
  go below iPadOS 17** (A10/A9 devices have no NE and would over-rely on the cloud).
- Apple Pencil note: Pencil Pro needs iPadOS 17.5+ (newest M-series/A17 Pro); USB-C Pencil 17.1.1+
  (no pressure); 2nd-gen covers iPad Pro 2018–2022 / Air 4–5 / mini 6. Pressure/tilt feed stroke-
  quality heuristics for recognition.

## The backend proxy (consequence of ADR 0002)

All Anthropic calls route through a **thin InkLab backend**, never directly from the iPad. Reasons:
ZDR eligibility (Messages API, server-side), API-key security (no key on device), and the mandated
input/output **moderation** for minors. The boundary:

- **On the iPad (offline-capable):** ink capture (PencilKit), on-device recognition (MyScript / Apple
  Vision), and all deterministic compute engines (CAS, units, chemistry validation, etc.).
- **Through the proxy (online + consent only):** Claude vision recognition (math fallback, chemistry,
  diagrams) and generative features (make-real, explanations). The proxy enforces the consent gate
  server-side, applies moderation, strips/min­imizes data, and is where any negotiated ZDR applies.

Latency budget (initial targets, tune in the spike): on-device recognition median **< 500 ms**; cloud
round-trip **1–4 s**, only on demand/fallback, with the "Read as…" shown immediately from the
on-device pass so the UI never blocks on the network.

Re-validate the floor and Neural-Engine assumptions at each new iPadOS release (iPadOS 27 will likely
raise the chip floor), and re-check for any new Apple ink/math API after WWDC.

---

## Implementation status (2026-06-07)

Status note (amends, does not change, the decision above).

- **Deployment target now set to iPadOS 18.0**, matching the floor in this ADR. It had been left at the
  default 26.4, which was blocking install on most iPads / the simulator.
- **Backend proxy is wired to the app and verified live** — `/make-real` (generative widgets) and
  `/recognize` (Claude vision) both confirmed end-to-end. The Anthropic API key lives in `Server/.env`
  (gitignored).
- **Proxy URL:** currently `localhost` for the simulator. For a real device the URL must point at the
  Mac's LAN IP or a deployed host — still TODO.

## Implementation status (2026-06-08)

Status note (amends, does not change, the decision above). Supersedes the 2026-06-07 "Proxy URL still
TODO" item — the proxy is now deployed.

- **iPadOS 18 floor holds** — unchanged from the decision; no revisit triggered.
- **Proxy deployed to an always-on host (Railway — INTERIM).** A real iPad can't reach the Mac's
  `localhost`, so the proxy now runs on an internet-reachable host. `railway.json` pins the Nixpacks
  builder + start command; `.nvmrc` pins Node; `.env` is never uploaded (gitignored + `.railwayignore`).
  The app's `MakeRealBaseURL` (`InkLab/Info.plist`) points at the Railway HTTPS URL. ⚠️ **Railway is
  not the final decision** — hosting/placement must be revisited **before publication**: region / data
  residency for minors, negotiated ZDR, moderation, and cost.
- **Auth-gated with a shared secret.** `/make-real` and `/recognize` require
  `Authorization: Bearer $INKLAB_PROXY_SECRET` whenever `INKLAB_PROXY_SECRET` is set (Railway variable;
  the app sends it from `Info.plist` `MakeRealProxySecret`); unset = open for local dev / tests, and
  `/health` is always open. The compare is timing-safe (`node:crypto` `timingSafeEqual`). ⚠️
  **Obfuscation-grade, not real auth** — a secret embedded in a distributed app can be extracted; this
  stops casual abuse of the public URL, not a determined attacker. Real per-user auth (tokens / App
  Attest) + rate limiting remain pre-ship items.
- **Consent re-checked server-side (defence-in-depth).** `/make-real` runs `cloudEligible(session)` and
  returns 403 for an ineligible session before any Anthropic call — the server enforces the consent/age
  gate independently of the app. `consent.ts` mirrors the Swift `DefaultCloudPolicy`.
- Make-real model is `claude-opus-4-8`, `maxTokens: 8192` (one pass, no truncation round-trips). Backend
  test suite: **23 passing** (`cd Server && npm test`, no network needed).
- **Still deferred (pre-ship):** real input/output moderation (currently an interface), negotiated ZDR
  wiring + data-retention policy, data minimization, verifiable parental consent, and the final
  hosting/placement decision that replaces interim Railway.

## Implementation status (2026-06-09)

Status note (amends, does not change, the decision above). iPadOS 18 floor + the proxy-only boundary are
both unchanged; this round hardens the proxy surface itself.

- **iPadOS 18 floor holds** — no revisit triggered.
- **Errors no longer leak internals.** The proxy used to return raw exceptions and the verbatim upstream
  Anthropic error body (including `request_id`). Responses are now generic — `500` "internal error" /
  `502` "upstream error" — and `anthropic.ts` no longer embeds the upstream body in the propagated error.
- **Request hardening:** an **8 MB request body-size cap** (over-cap → **413**), and **`400` on
  malformed/missing JSON** (previously surfaced as a `500`).
- **Widget validator broadened (defense-in-depth).** `validateWidgetHtml` now also screens `img`,
  `<meta refresh>`, `<base>`, `sendBeacon`, WebSocket / EventSource, dynamic `import()`, css `url()`, and
  protocol-relative `//`; its comment now correctly states the **on-device WKWebView CSP is the real
  boundary** (this validator is belt-and-suspenders). `stripMarker` now removes only the trailing DONE
  marker, not every occurrence.
- **Backend test suite: 23 passing** (`cd Server && npm test`, no network needed).
- **Still deferred (pre-ship):** real per-user auth (tokens / App Attest) + rate limiting, and real
  input/output moderation — all remain pre-ship, alongside the items above.
- ↪ **The proxy stays STATELESS (2026-06-17, [ADR 0006](0006-backup-and-sync.md)).** Notebook
  backup/sync is **serverless** — a Files/iCloud-Drive export, then CloudKit — so the backend proxy
  forwards prompts to Claude and stores **no** user content. It must not become a notebook store
  (that would reopen the data-residency-for-minors question this proxy exists to contain).
