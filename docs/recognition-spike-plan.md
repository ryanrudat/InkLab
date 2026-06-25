# Recognition spike — go/no-go before broad build

**Goal:** prove MyScript clears the accuracy + privacy + licensing gates on **real messy student
math** before we build the math wedge broadly. If it misses, flip `.math` to Claude-vision-primary
(a one-line change in `DefaultRecognizerStack` / `RoutingRecognizer`). Timebox: **1–2 weeks.**

> Note: building/running this requires an iPad + Xcode + the MyScript SDK + real Pencil strokes, which
> can't be done in a headless CLI. The `InkLabRecognition` package + harness interface exist now; the
> on-device app shell and the MyScript/Vision/Claude bridges are wired during the spike on hardware.

## 1. Corpus first (the corpus IS the experiment) — ~1–2 days
- **150–300 real student STEM expressions**, captured **natively on iPad with Apple Pencil** (true
  strokes — NOT photos of paper; MyScript/ML Kit need online stroke data).
- Recruit **8–15 students** across neatness levels; left- and right-handed; varied pressure.
- Composition: arithmetic/fraction chains; multi-line algebra (solve-for-x worked steps); calculus
  (∫, d/dx, limits, Σ, exponents/subscripts, √, matrices).
- **Hand-label ground-truth LaTeX** for each. Hold out the messiest 20% as a separate "torture" gate.
- Get the students'/parents' consent for this test use (keeps the spike clean re: ADR 0002).

## 2. Harness (~3–4 days)
- `PKCanvasView` capture → bridge `PKStroke` → `InkStroke` and `PKDrawing.image()` → `RasterImage`.
- Call **MyScript (on-device)** and **Claude vision (cloud, via the proxy)** behind the existing
  `InkRecognizer` protocol — the spike harness *is* the production interface.
- Pipe each provider's LaTeX/JIIX into the deterministic parser to confirm it yields a **valid
  expression tree** (parse-validity is half the battle — see `FormalStructureValidator`).
- Implement the routing gate (low-confidence → Claude second opinion) to validate the hybrid UX too.

## 3. Accuracy gates (MyScript, on the student corpus)
| Metric | GO threshold | Note |
|---|---|---|
| Expression-level exact match | **≥ 70%** full set · **≥ 50%** messy-20% | HMER SOTA on curated sets is ~64–80%, so >70% on real ink is strong |
| Symbol-level accuracy | **≥ 90%** | "mostly right, one symbol off" is salvageable by the correction UX |
| Parse-validity (LaTeX/JIIX → tree) | **≥ 95%** | un-parseable output is useless regardless of string accuracy |
| Latency (median, target iPad) | **< 500 ms** | interactive |
| Fallback lift | Claude recovers **≥ 40%** of MyScript sub-threshold misses | else the hybrid isn't earning its cost |

Also measure Claude's **hallucination rate** (confident-but-wrong that still passes the parser) — if
non-trivial, tighten the "Read as…" confirm UX.

## 4. Non-accuracy gates (parallel, must clear before commit)
- **Written MyScript on-device license quote** (pricing is quote-only) — viable at student scale?
- **Written clarification on license §18.3** (MyScript accessing end-user input) — confirm it requires
  explicit opt-in and is fully disableable for a minors product.
- Confirm one-time activation behavior + SDK binary/model on-disk size for the current 4.x release.

## 5. Go / No-go
- **GO (MyScript-primary):** clears accuracy + latency + parse gates AND license quote/§18.3 are
  acceptable.
- **NO-GO → Claude-vision-primary** (cloud, consent-gated, per-call cost): if MyScript misses the
  accuracy bar OR the license is too costly/restrictive OR §18.3 can't be constrained for minors.

Either outcome is a one-line provider swap in the router — which is the entire point of the interface.

---

## Update (2026-06-08) — interim recognizer in place and now driving more of the app; MyScript spike still deferred

The MyScript spike above is **DEFERRED until a MyScript license + SDK are obtained**. The rest of
this plan still stands. In the meantime, recognition is wired with the providers we have today,
**both behind the `InkRecognizer` protocol** (`ClaudeVisionRecognizer` + `VisionTextRecognizer`):

- **Interim primary: Claude-vision** (cloud, via the proxy `/recognize`) — working end-to-end; reads
  both handwriting and the `@` ask-marker correctly. Consent-gated: it fires only when the cloud-AI
  opt-in is granted (`makeRealSession.blockReason == nil`); the server re-checks the session.
- **On-device / offline fallback: Apple Vision** — kept for the key-free/offline path, but it proved
  **unreliable for symbols** (it misreads a handwritten `@` as `a`), which is why the Recognize path
  prefers Claude.

Both providers are reached through one shared `bestRead(...)` path (try cloud when consented, else
Apple Vision on-device), so every recognition surface in the app uses the same swappable stack:

- **The Recognize button** (lasso → read → draft) — the original surface.
- **The deterministic engine chips** — recognized text feeds the engines wired into the toolbar today
  (InkLabMath Check working / Differentiate, InkLabUnits, InkLabChem Balance / Molar mass,
  InkLabBio DNA→Protein / Punnett). (The InkLabFit "Fit" chip is the exception — it samples lasso
  stroke points geometrically and needs **no** OCR/recognition at all.)
- **Handwrite-to-plot on widgets (NEW 2026-06-08)** — the ✏️/ƒ chrome on a generated make-real
  widget. Writing on the widget's annotation layer, then tapping **ƒ**, calls the same consent-gated
  `bestRead(...)`, trims the read to a bare expression (`y = …`/`f(x) = …` → the RHS), and feeds it
  into the widget via the widget input protocol (`window.inklab.setInput(text)`, with a best-effort
  JS fallback). Same recognizer as the Recognize button — no second provider path.

This is the NO-GO §5 posture (Claude-vision-primary) running provisionally as the default, pending the
MyScript license/SDK and the on-real-ink accuracy spike — at which point the go/no-go gates above apply.

---

## Update (2026-06-09) — recognizer stack unchanged; one new reach surface

The interim stack above is **unchanged**: Claude-vision primary (cloud, via the proxy, consent-gated),
Apple Vision on-device fallback, MyScript spike still **deferred**. No change to the go/no-go plan.

- **Recognize is now also reachable from the lasso selection edit menu** — tapping inside a lasso
  selection offers Recognize (alongside Check work / Fit), all running the same shared `bestRead(...)`
  path. Just one more surface on the existing swappable stack — no new provider path.
- The **"Check working"** verb was renamed **"Check work"** on the lasso edit-menu and dock surfaces
  (the engine chip noted in the 2026-06-08 update above is the same InkLabMath path; the legacy
  `EngineKit` chip title and the recognition-review help text still read "Check working").

---

## Update (2026-06-25) — recognizer stack still unchanged; spike still the gate before MyScript

No change to recognition since the 2026-06-09 update. Verified against the codebase today:

- **Stack:** Claude-vision primary (cloud, via the proxy, consent-gated), Apple Vision on-device
  fallback, MyScript still **deferred**. All three providers remain stubs in the package
  (`MyScriptRecognizer` / `AppleVisionRecognizer` / `ClaudeVisionRecognizer` in
  `InkLabRecognition/Providers` throw `.notImplemented`); the app's live readers are
  `ClaudeVisionRecognizer` + `VisionTextRecognizer` in `InkLab/InkLab`, both behind `InkRecognizer`
  and reached through the single `bestRead(...)` path in `CanvasViewController` (consent check is
  `makeRealSession.blockReason == nil`).
- The recent dock rewrite (drag in global coords + side-wall snap to a vertical reflow) is a
  toolbar UX change only — it does **not** touch any recognition surface or provider path. Recognize
  and Check work are still reached from the dock and the lasso edit menu, both running `bestRead(...)`.
- Provisional posture is unchanged: this is the §5 **NO-GO (Claude-vision-primary)** path running as
  the default, pending the MyScript license/SDK and the on-real-ink accuracy spike — at which point
  the go/no-go gates in §3–§5 apply as written.
