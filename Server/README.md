# InkLab proxy (backend)

The server-side boundary for **all** Anthropic calls (ADR 0002 / [ADR 0003](../docs/decisions/0003-ipados-floor-and-backend-proxy.md)).
The iPad never calls Anthropic directly — it calls this proxy, which holds the API key, enforces the
consent/age gate, applies moderation, and keeps zero-data-retention posture. TypeScript, run directly
by Node 23+ (native type-stripping — no build step).

## Run
```sh
cd Server
npm test                                   # 19 tests (node --test) — no network needed
ANTHROPIC_API_KEY=sk-... npm start         # starts the proxy on :8787
```

## Endpoints
- `POST /recognize` — `{ session, rasterPngBase64, strokes, domain, context }` → a **validated**
  `RecognitionResult` (the cloud fallback for the swappable recognizer). Correct-or-silent: anything
  that doesn't parse to valid structure comes back as `unrecognized`, never a guess.
- `POST /make-real` — `{ session, prompt }` → a self-contained widget `{ html, complete, passes }`,
  built with the **multi-pass assembler** (continues past truncation, stitches) and rejected (422) if
  it isn't sandbox-safe.
- `GET /health` → `{ ok: true }`.

## The tested core (`src/`)
- `consent.ts` — `cloudEligible(session)`; mirrors the Swift `DefaultCloudPolicy`. The server enforces
  it independently (defence-in-depth for minors' data — it never calls Anthropic for an ineligible
  session).
- `assembler.ts` — the make-real multi-pass assembler (`DONE_MARKER`; feed-partial-back-and-stitch).
- `validate.ts` — `validateRecognition` (correct-or-silent) and `validateWidgetHtml` (no external
  network loads, so it runs in a locked-down WKWebView).
- `recognize.ts` — orchestration (gate → prompt → call → validate).
- `anthropic.ts` — the real HTTP client behind the `AnthropicClient` interface (mocked in tests).

## Deferred (pre-ship)
- Real input/output **moderation** (Organizations-Serving-Minors safeguard) — currently an interface.
- Negotiated **ZDR** wiring + a written data-retention policy; data minimization (crop/strip).
- Verifiable parental-consent verification, auth, rate limiting, deploy. See
  [docs/compliance-checklist.md](../docs/compliance-checklist.md).
