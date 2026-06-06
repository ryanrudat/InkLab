# InkLab

An iPad-first, Apple Pencil-native STEM note-taking app built on one idea: **anything a student
writes or draws on the page can become a live, correct, manipulable object.**

Core architecture — **READ vs COMPUTE**: the recognizer/model only *translates* messy ink into a
formal structure (LaTeX, expression tree, SMILES, netlist); **deterministic engines** produce the
result, so output is correct by construction. The defensible moat is the in-context spatial canvas +
the deterministic execution/verification layer + breadth — not raw LLM intelligence.

## Status

Phase 0, foundation. **All four §12 foundational decisions are resolved** (recognition #1, object
model #3, canvas #2, on-device/cloud boundary #4), each backed by runnable, tested code, and the
deterministic STEM engines — the **math wedge** (red-pen tutor, **algebra + calculus**), the **units /
dimensional conscience**, **chemistry** (formula/molar-mass + equation balancing), and **biology**
(transcription/translation, mutations, Punnett squares), **reactive worked-solutions** (spreadsheet-
style dependency recompute), **lab-notebook curve fitting** (least squares + R² + error bars), **linked multi-representation**
(equation↔table↔best-fit), the **intent router** (`@`-command → deterministic engine / native widget / generative make-real),
**notebook search** (inverted index over recognized + typed text), and the canvas **geometry core**
all have working, tested cores. **114 passing tests across twelve pure-Swift library packages** (+ the
`InkLabKit` umbrella), plus a **19-test TypeScript backend proxy** (`Server/`). Next: the on-device
phase (iOS app + the canvas device gates).

**→ See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the whole system at a glance (package map, pipeline, path to ship).**

## Decisions so far

| # | Decision | Where |
|---|---|---|
| Recognition provider | MyScript (on-device math) · Apple Vision (text) · Claude vision (cloud fallback + chem/diagrams), behind a swappable interface; **spike-gated** | [ADR 0001](docs/decisions/0001-recognition-provider.md) |
| Minors + cloud-AI | **Policy A** — cloud + verifiable parental consent, on-device-only fallback when absent | [ADR 0002](docs/decisions/0002-minors-cloud-compliance.md) |
| iPadOS floor + backend | **iPadOS 18** floor; all Claude calls via a server-side proxy | [ADR 0003](docs/decisions/0003-ipados-floor-and-backend-proxy.md) |
| Object model + persistence | **Event-sourced op-log** ("journal") — global undo, never-lose-ink, rewrite-free collab; core built & tested | [ADR 0004](docs/decisions/0004-object-model.md) |
| Canvas rendering | **PKCanvasView-hosted hybrid** — native ink/zoom + object overlay; geometry core built & tested, device-gated | [ADR 0005](docs/decisions/0005-canvas-rendering.md) |

Also see [the recognition spike plan](docs/recognition-spike-plan.md) (go/no-go before broad build)
and the [compliance checklist](docs/compliance-checklist.md) (pre-ship).

## Layout

```
Packages/
  InkLabRecognition/      Swappable recognition abstraction (platform-agnostic Swift package).
    Sources/.../          InkRecognizer protocol, RoutingRecognizer (on-device-first +
                          confidence-gated cloud escalation + consent gate), provider stubs.
    Tests/                Routing/consent behavior, verified on the CLI.
  InkLabDoc/              The document core — the event-sourced "journal" everything sits on.
    Sources/.../          Model (Op/OpPayload/ObjectSnapshot/ObjectPayload) + engine
                          (fold/invert/merge/remap). Foundation-only; ink bytes are opaque (BlobRef).
    Tests/                Undo, merge (never-lose-ink), convergence, compaction, paste — CLI-verified.
  InkLabMath/             The red-pen tutor — deterministic algebra + calculus (exact rationals →
    Sources/.../          canonical form; symbolic differentiation). First-wrong-line checker.
    Tests/                Algebra/calculus equivalence + tutor verdicts + counterexamples — CLI-verified.
  InkLabUnits/            The "dimensional conscience" — SI dimensions, a unit registry with
    Sources/.../          prefixes, and a checker that flags unit mismatches in formulas/equations.
    Tests/                Dimension algebra, unit parsing, consistency checks — CLI-verified.
  InkLabChem/             Deterministic chemistry — formula parsing + molar mass, and equation
    Sources/.../          balancing as the exact integer null-space of the conservation matrix.
    Tests/                Formula/molar-mass + balancing (water, rust, combustion…) — CLI-verified.
  InkLabBio/              Deterministic biology — DNA→mRNA→protein (genetic code), point-mutation
    Sources/.../          classification, and Punnett squares (mono/dihybrid).
    Tests/                Transcription/translation, mutations, 3:1 & 9:3:3:1 ratios — CLI-verified.
  InkLabCanvasCore/       The canvas geometry "brain" — lasso hit-testing, transform math, canvas↔view
    Sources/.../          mapping, page auto-extend, page-turn classifier, projection→view diff.
    Tests/                All geometry/selection/paging logic — CLI-verified (PencilKit stays on-device).
  InkLabReactive/         Reactive worked-solutions — a dependency graph of cells; change a "knob" and
    Sources/.../          downstream values recompute (spreadsheet mechanics), with cycle detection.
    Tests/                Recompute, propagation, cycles, undefined refs — CLI-verified.
  InkLabFit/              Lab-notebook curve fitting — linear/polynomial/exponential/power least
    Sources/.../          squares with R² and parameter standard errors (error bars).
    Tests/                Exact + noisy fits, error bars, degenerate inputs — CLI-verified.
  InkLabMultiRep/         Linked multi-representation — equation→table (sample) and table→equation
    Sources/.../          (parsimonious best-fit); a coordinator that keeps the forms in sync.
    Tests/                Sampling, best-fit model selection, round-trips — CLI-verified.
  InkLabRouter/           The intent router + "@" ask-marker — parses an @command / classifies a
    Sources/.../          selection, then dispatches (deterministic engine · native widget · make-real).
    Tests/                Command parsing, dispatch, action chips — CLI-verified.
  InkLabSearch/           Notebook search — an inverted index (prefix matching, ranking) over recognized
    Sources/.../          + typed text, with an extractor that reads searchable text from the journal.
    Tests/                Matching, prefix, AND queries, ranking, journal extraction — CLI-verified.
  InkLabKit/              Umbrella package — re-exports all libraries (the app uses `import InkLabKit`).
docs/
  decisions/              ADRs 0001–0004.
  red-pen-tutor.md, recognition-spike-plan.md, compliance-checklist.md
```

Engine packages (CAS, units, chemistry validation, …) and the iOS app target are added as the
vertical slices land — each engine behind a clean interface, with tests (brief §0).

## Build & test

```sh
( cd Packages/InkLabRecognition && swift test )   # 9 tests
( cd Packages/InkLabDoc         && swift test )    # 7 tests
( cd Packages/InkLabMath        && swift test )    # 21 tests — the red-pen tutor (algebra + calculus)
( cd Packages/InkLabUnits       && swift test )    # 9 tests — the dimensional conscience
( cd Packages/InkLabChem        && swift test )    # 9 tests — chemistry (balancing + molar mass)
( cd Packages/InkLabBio         && swift test )    # 8 tests — biology (genetics + sequences)
( cd Packages/InkLabCanvasCore  && swift test )    # 11 tests — canvas geometry (lasso/transform/paging)
( cd Packages/InkLabReactive    && swift test )    # 9 tests — reactive worked-solutions
( cd Packages/InkLabFit         && swift test )    # 6 tests — lab-notebook curve fitting
( cd Packages/InkLabMultiRep    && swift test )    # 8 tests — linked multi-representation
( cd Packages/InkLabRouter      && swift test )    # 11 tests — intent router + @ ask-marker
( cd Packages/InkLabSearch      && swift test )    # 6 tests — notebook search
```

Requires Swift 6 (Xcode 26+). Both packages are intentionally Foundation-only so their logic is
testable without an iPad. The iOS app provides the PencilKit adapter (`PKStroke`→`InkStroke`,
`PKDrawing`→`RasterImage`/`BlobRef`), the GRDB local store + `CKSyncEngine` transport for `InkLabDoc`,
and the concrete MyScript/Vision/Claude bridges for `InkLabRecognition`.

## Run the iPad app

The app lives in `InkLab/InkLab.xcodeproj` (open it in Xcode and Run on an iPad). Its canvas code is in
`InkLab/InkLab/` (`CanvasViewController`, `ObjectOverlayView`, `JournalStore`, `PencilKitAdapters`) and
it depends on the **`InkLabKit`** umbrella package (`Packages/InkLabKit`), which re-exports all seven
libraries — so the app just writes `import InkLabKit`. The package is already wired into the project.

It implements the ADR-0005 spine (pencil-draws/finger-navigates, object overlay over ink, finger+Pencil
lasso, journal-backed undo) as a thin slice. ⚠️ This target builds **only in Xcode** (needs the iOS SDK)
— it's the starting point for the on-device gates, not covered by the 74 CLI tests.

## Backend proxy (`Server/`)

All Anthropic calls go through a server-side proxy (ADR 0002) — the iPad never holds the API key. It
enforces the consent/age gate, runs the make-real multi-pass assembler, and validates model output
(correct-or-silent). TypeScript, run directly by Node 23+ (no build step):
```sh
cd Server && npm test                          # 19 tests, no network
ANTHROPIC_API_KEY=sk-... npm start             # proxy on :8787
```
See [Server/README.md](Server/README.md).

## Next (the on-device phase)

All four §12 foundational decisions are resolved and their CLI-verifiable cores are built. What
remains is iPad-coupled (writable here, but runnable only in Xcode):

- **Flesh out the canvas** in `InkLab/InkLab.xcodeproj` per [ADR 0005](docs/decisions/0005-canvas-rendering.md):
  ink↔journal sync, native scroll/zoom + paging, the GRDB local store + `CKSyncEngine` transport.
- **The canvas device-gate prototype** (Gate A native-zoom crispness/registration … Gate E lasso perf).
- **The recognition spike** on a real iPad (see [docs/recognition-spike-plan.md](docs/recognition-spike-plan.md)).
- **Compliance track** toward ship (see [docs/compliance-checklist.md](docs/compliance-checklist.md)).

Foundational/irreversible choices are proposed with trade-offs before broad implementation (brief §0).
