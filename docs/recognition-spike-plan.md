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
