# ADR 0001 — Recognition provider

**Status:** Accepted (spike-gated) · 2026-06-06 (interim Vision + Claude stack wired 2026-06-07; MyScript spike still pending as of 2026-06-25)
**Resolves:** Build brief §12 #1 (highest-priority open decision)

## Context

InkLab's architecture is **READ vs COMPUTE**: the recognizer only *translates* messy ink into a
formal structure (LaTeX, expression tree, SMILES, netlist); deterministic engines produce the
result. So the recognizer's job is bounded — turn ink into formal structure with high fidelity —
but it is the single highest technical risk, and the whole product rests on it. We need: high
accuracy on **messy real student math** (the wedge), a strong **on-device/minors** privacy posture,
and a provider that stays **swappable/reversible**.

Research (fact-checked, June 2026) established:

- **Apple exposes no usable math (or own-canvas text) recognition API.** PencilKit captures ink but
  recognizes nothing; Scribble injects text only into system text fields ("not intended to be a
  general purpose handwriting recognition API" — Apple HIG); Math Notes is a closed Notes/Calculator
  feature with no SDK; Vision OCR is raster-only, printed-text-oriented, returns flat strings with no
  math layout/LaTeX. **Apple is viable only for on-device text** (notes/search).
- **MyScript iink (native, on-device) is the only on-device option that emits formal math
  structure** — LaTeX + MathML + a JIIX expression tree — from online strokes. Pricing is quote-only;
  one online activation then runs offline (the "re-validate every 30 days" claim was refuted — it's a
  one-time activation window). License §18.3 contemplates accessing end-user input with consent → a
  diligence item for a minors product.
- **Claude vision** (already in our stack) is a capable but cloud, per-call, hallucination-prone
  recognizer with no measured CROHME accuracy — best as escalation + long-tail, never auto-trusted.
- **Chemistry/diagrams** have no on-device path and are hard industry-wide (hand-drawn structure →
  SMILES tops out ~73% with specialized tools; general OCSR collapses on hand-drawn) → best-effort.

## Decision

A **tiered, swappable stack behind one `InkRecognizer` protocol**:

| Domain | Primary | Output | Fallback |
|---|---|---|---|
| **Math** (wedge) | **MyScript iink, on-device** | LaTeX + MathML + JIIX tree | Claude vision (low conf / parse fail) |
| **Text** (notes/search) | **Apple Vision**, on-device | plain strings | Claude vision (hard pages) |
| **Chemistry** | **Claude vision** → SMILES (RDKit-validated) | SMILES | — (cloud-only, best-effort) |
| **Diagrams** | **Claude vision** → JSON/netlist | netlist | — (experimental, post-MVP) |

Rules (encoded in `RoutingRecognizer`, with tests):
1. On-device first; accept iff confidence ≥ threshold **and** the deterministic validator passes.
2. Escalate to cloud only when the consent/connectivity gate allows (see ADR 0002).
3. **Never auto-accept cloud output without a successful deterministic parse** + a user-confirmable
   "Read as…" — the engine is the correctness authority.
4. Cloud-only domain while blocked → explicit `.unrecognized`, never a silent send or a guess.

This recommendation is **conditional on the spike** (docs/recognition-spike-plan.md) clearing the
accuracy gate on a real messy-student corpus, plus a written MyScript on-device license quote and a
written answer on §18.3. If either fails, the interface lets us flip `.math` to Claude-vision-primary
in one registration line.

## Implementation status (2026-06-07)

Two of the planned providers are now wired behind the `InkRecognizer` protocol:

- **Apple Vision** (on-device, free) — implemented in the app target as `VisionTextRecognizer`;
  reads flat text.
- **Claude vision** (cloud, via the proxy `/recognize` endpoint) — implemented as
  `ClaudeVisionRecognizer`.

Notable finding: **Apple Vision misreads a handwritten "@" as "a"**, while **Claude reads the "@"
correctly (0.97 confidence)**. Because of this, the Recognize / auto-`@` path uses **Claude with
Apple Vision as the offline/free fallback** — a swap made possible by the protocol abstraction, as
the ADR intended.

**MyScript** remains the planned on-device math provider but is **NOT yet integrated** (needs a paid
license + their binary SDK the user must obtain). Structured math (exponents/fractions) therefore
isn't available yet — both wired providers return flat text. **The spike (the gate above) is still
pending.**

## Implementation status (2026-06-08)

The interim recognizer stack from 2026-06-07 is unchanged in shape — Apple Vision
(`VisionTextRecognizer`, on-device) + Claude vision (`ClaudeVisionRecognizer`, cloud via the proxy,
consent-gated per ADR 0002), both behind the `InkRecognizer` protocol; **MyScript primary is still a
DEFERRED spike** (no license/SDK yet).

New today: **recognition also powers handwrite-to-plot on generated widgets.** A `WidgetAnnotationView`
ink layer sits above each make-real widget; the ƒ header button rasterises that annotation and runs it
through the **same recognizer used by the Recognize button** (consent-gated, identical
`InkRecognizer` path), then feeds the recognized text into the widget via the new widget input contract
(`window.inklab.setInput(text)`, with a best-effort JS fallback in `WebWidgetView.setInput`). So the
recognizer's "translate ink → formal/text, engines/widgets compute" boundary now extends onto live
widgets — no change to the provider decision, just a new consumer of the existing path.

## Implementation status (2026-06-09)

The recognizer stack is **unchanged in shape** — Apple Vision (`VisionTextRecognizer`, on-device) +
Claude vision (`ClaudeVisionRecognizer`, cloud via the proxy, consent-gated per ADR 0002), both
behind the `InkRecognizer` protocol; **MyScript primary is still a DEFERRED spike** (no license/SDK
yet). No provider decision change.

New today: **recognition is now also reachable from the lasso SELECTION edit menu.** Recognize /
Check / Fit act on a lassoed mixed selection of handwriting + objects, running the **same
consent-gated `InkRecognizer` path** — so the recognizer's reach now extends to direct-manipulation
selections, again just a new consumer of the existing path. Also: **"Check working" was renamed
"Check work"** everywhere it appears.

## Consequences

- **+** On-device math keeps minors' highest-volume ink on the iPad; correct-by-construction via the
  engines; predictable cost (no per-recognition fee for the wedge); the Anthropic fallback is free
  architecturally.
- **−** Two engines to integrate and a confidence threshold to tune; MyScript license cost is
  quote-only (budget risk, mitigated by the spike + reversibility); §18.3 must be contractually
  constrained for minors.
- The `InkRecognizer` abstraction (platform-agnostic Swift package `InkLabRecognition`) is the
  reversibility insurance and exists today with passing tests.

## Alternatives considered

- **Apple-only:** rejected — structurally cannot do math/chemistry/diagrams.
- **Claude-vision-primary for math:** rejected as primary — general VLMs trail specialized HMER on
  messy input and Claude has no published accuracy number; kept as fallback. (Becomes the fallback
  plan if the spike fails MyScript.)
- **Mathpix:** cloud-only, 18+ ToS, `improve_mathpix` defaults true → not minor-safe by default;
  only behind the same consent gate if Claude chemistry proves inadequate.
- **Google ML Kit Digital Ink:** on-device text, but no math model and transmits device/install
  identifiers to Google (COPPA disclosure) → held as the text alternative only if Vision is weak.
