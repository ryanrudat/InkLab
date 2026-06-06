# InkLab — Architecture & Roadmap

One page tying the whole system together. For the *why* behind each decision see the ADRs in
[docs/decisions/](decisions/).

## Thesis: READ vs COMPUTE
The recognizer/model only **translates** messy ink into a **formal structure** (LaTeX, expression
tree, SMILES, sequence, netlist). **Deterministic engines** then produce the result, so output is
correct *by construction* — never an LLM's guess. The moat is the in-context spatial canvas + this
execution/verification layer + breadth, not the raw intelligence.

## System shape
```
        iPad (Swift)                                   Cloud boundary (only with consent)
 ┌───────────────────────────────────────┐      ┌──────────────────────────────────────┐
 │ PencilKit ink  ┐                       │      │  Server/ proxy  ──►  Anthropic API    │
 │ object overlay ┘ canvas (ADR 0005)     │      │  • consent/age gate (server-enforced) │
 │        │                               │      │  • make-real multi-pass assembler     │
 │   InkLabDoc journal (object model)     │      │  • correct-or-silent validation       │
 │        │                               │      └──────────────────────────────────────┘
 │   on-device recognition (swappable)    │                         ▲
 │        │                               │   only the lassoed region, only with consent │
 │   InkLabRouter  ──►  deterministic engines (math/units/chem/bio/…) ─ correct by construction
 │                 ├─►  native widgets (e.g. scientific calculator)
 │                 └─►  generative make-real ───────────────────────┘ (via the proxy)
 └───────────────────────────────────────┘
```

## The pipeline (§4.2)
`select region / @command → rasterize (+ strokes) → router classifies intent → dispatch`:
- **deterministic** → a vetted engine (`InkLabMath` solve/red-pen, `InkLabChem` balance, …)
- **native** → a vetted widget (calculator)
- **generative** → make-real via the proxy, then validated/sandboxed
→ result rendered as a live object → written to the **journal** (global undo, conflict-free merge).

## Package map (all CLI-tested)
| Package | Role | Tests |
|---|---|---|
| InkLabRecognition | swappable handwriting→formal-structure routing + consent gate | 9 |
| InkLabDoc | the journal / object model (fold·invert·merge·remap) | 7 |
| InkLabCanvasCore | canvas geometry (lasso·transform·coords·paging) | 11 |
| InkLabMath | red-pen tutor — algebra + calculus | 21 |
| InkLabUnits | dimensional conscience | 9 |
| InkLabChem | balancing + molar mass | 9 |
| InkLabBio | DNA→protein · mutations · Punnett | 8 |
| InkLabReactive | reactive worked-solutions (knob → recompute) | 9 |
| InkLabFit | lab-notebook least-squares + R² + error bars | 6 |
| InkLabMultiRep | equation ↔ table ↔ best-fit | 8 |
| InkLabRouter | intent router + "@" ask-marker | 11 |
| InkLabSearch | notebook content search | 6 |
| InkLabKit | umbrella — re-exports all of the above (`import InkLabKit`) | — |
| Server/ (TS) | backend proxy — gate · assembler · validation | 19 |
| **Total** | | **133** |

## Decisions (ADRs)
- **0001** Recognition: MyScript (on-device math) · Apple Vision (text) · Claude (cloud fallback + chem/diagrams), swappable; spike-gated.
- **0002** Minors/cloud: **Policy A** — cloud + verifiable parental consent; ship general-audience; backend proxy required.
- **0003** iPadOS 18 floor; all Anthropic calls via the proxy.
- **0004** Object model: event-sourced op-log ("journal").
- **0005** Canvas: PKCanvasView-hosted hybrid (native ink/zoom + object overlay).

## Path to ship — done vs left
**Done & verified here (no device needed):** the 12 libraries + the proxy core — 133 tests. The
deterministic brain, the dispatch layer, and the cloud boundary.

**Left — runtime-coupled (needs an iPad / real services):**
1. **App** — `InkLab/InkLab.xcodeproj` slice runs; flesh out ink↔journal sync, native scroll/zoom + §5.2 paging.
2. **Canvas device gates** (ADR 0005): A native-zoom crispness + overlay registration · B gesture partition feel · C multi-canvas memory · D ink round-trip + recognition · E lasso-drag perf.
3. **WKWebView compute sandbox** — host make-real widgets + the JS engines (math.js/Pyodide/three.js/RDKit/ngspice).
4. **Wire the real Anthropic calls** into the proxy + input/output moderation + negotiated ZDR.
5. **Persistence/sync** — GRDB local store + `CKSyncEngine` for `InkLabDoc`.
6. **Recognition spike** — validate MyScript on real messy student math (see [recognition-spike-plan.md](recognition-spike-plan.md)).
7. **Compliance pre-ship** — the counsel/contract gates (see [compliance-checklist.md](compliance-checklist.md)).

## Build & run
- Swift libs: `( cd Packages/<name> && swift test )` — see the [README](../README.md) for the full list.
- Proxy: `( cd Server && npm test )`, `ANTHROPIC_API_KEY=… npm start`.
- App: open `InkLab/InkLab.xcodeproj`, Run on an iPad (`InkLabKit` is linked).
