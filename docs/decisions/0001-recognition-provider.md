# ADR 0001 — Recognition provider

**Status:** Accepted (spike-gated) · June 2026
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
