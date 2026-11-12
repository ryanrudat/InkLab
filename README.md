# InkLab

An iPad-first, Apple Pencil-native STEM note-taking app built on one idea: **anything a student
writes or draws on the page can become a live, correct, manipulable object.**

Core architecture — **READ vs COMPUTE**: the recognizer/model only *translates* messy ink into a
formal structure (LaTeX, expression tree, SMILES, netlist); **deterministic engines** produce the
result, so output is correct by construction. The defensible moat is the in-context spatial canvas +
the deterministic execution/verification layer + breadth — not raw LLM intelligence.

## Status

Foundation built, **and the iPad app now runs end-to-end**. All four §12 foundational decisions are
resolved (recognition #1, object model #3, canvas #2, on-device/cloud boundary #4), each backed by
runnable, tested code, and the deterministic STEM engines — the **math wedge** (red-pen tutor,
**algebra + calculus**), the **units / dimensional conscience**, **chemistry** (formula/molar-mass +
equation balancing), and **biology** (transcription/translation, mutations, Punnett squares),
**reactive worked-solutions** (spreadsheet-style dependency recompute), **lab-notebook curve fitting**
(least squares + R² + error bars), **linked multi-representation** (equation↔table↔best-fit), the
**intent router** (`@`-command → deterministic engine / native widget / generative make-real),
**notebook search** (inverted index over recognized + typed text), and the canvas **geometry core**
all have working, tested cores. **145 package tests across 12 pure-Swift library packages** (plus the
`InkLabKit` umbrella), plus **47 app unit tests + UI tests** (the iPad target), plus a **TypeScript
backend proxy** (`Server/`, **85 tests**). New (2026-11-12): a **Socratic tutor** on top of the red pen
(hints and questions, never the answer; see below). The journal now **persists to disk** (append-only op log +
ink blobs) and survives relaunch, reopening the last-viewed page.

**Implementation status (2026-06-09):** lasso is now **direct manipulation** (move + delete/cut/copy/paste
of mixed ink+objects); the **home library** was redesigned (uniform elevated, drag-to-reorder, recolorable,
renameable notebooks); the **toolbar/dock** was reworked (contextual inline color/thickness, per-tool pen
favorites, a repositionable + collapsible dock, a `＋` Insert/Actions menu); and a **correctness/safety
hardening pass** landed — the server consent gate is now **fail-closed**, the deterministic engines are
**overflow-safe (correct-or-silent)**, `numericValue` is finite-or-nil, and several persistence/async-race
bugs were fixed. See the dated bullets in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and the ADRs.

**Implementation status (2026-06-16 → 18):** writing-experience and robustness work (built + verified;
the draw-and-hold fix confirmed on a real iPad + Pencil, the undo fix build- + regression-test-verified,
each behind a multi-agent adversarial review). **Paper style now persists** per notebook (was reverting to ruled on relaunch).
**Stylus rework:** bolder pens (3/6/10), **color and thickness are independent** (picking a color no
longer resets the width), and saved colors live in a **scrollable strip** so the dock can't overflow.
**Draw-and-hold shape snapping** (new): hold the pencil ~0.5s after a stroke and a line/arrow/circle/
rectangle/triangle snaps to a clean form — a deterministic `ShapeRecognition` engine in `InkLabCanvasCore`
(+14 tests), one undo step. **Undo no longer "comes back"** — fixed the bug where undoing then re-drawing
resurrected the undone ink: a programmatic `canvasView.drawing` swap commits through PencilKit's **async
render pipeline**, so the next stroke could be composited onto the pre-swap drawing; the delegate now
**strips any removed stroke that reappears, by content-signature** (`dataRepresentation()` is not a stable
identity). And a **backup decision** (ADR 0006):
back up serverlessly via a Files/iCloud-Drive export then CloudKit — **not** on our server.

**Implementation status (2026-06-25):** the **floating dock was rewritten**. (1) **Drag jitter fixed** —
the drag is now tracked in **global** coordinates and the dock is moved with `.position` (the old
`.local`-space `DragGesture` + `.offset` was a feedback loop that vibrated). (2) **NEW — edge docking:**
dragging the dock to either **side wall** snaps it flush and **reflows it vertical** (an `AnyLayout`
horizontal↔vertical swap); dropping it elsewhere floats it as a horizontal capsule, and it behaves
identically in both orientations. Position + placement persist as **fractions of the container**, so they
survive rotation and split-view. The repo is now **public on GitHub** — see [How to run](#how-to-run).

### Current state (what runs today)

- **On-device canvas** — drawable in the Simulator (PencilKit, `.anyInput` finger/mouse draw; a
  Settings toggle switches to pencil-draws/finger-navigates on iPad). Object overlay over ink,
  journal-backed undo.
- **Recognition (READ)** — Apple **Vision** on-device (free/offline fallback) + **Claude vision**
  via the proxy. The Recognize button uses Claude (Apple Vision misreads a handwritten "@" as "a";
  Claude reads it correctly). A "Read as…" review sheet shows the editable transcription + engine chips;
  lasso-region recognition reads just the selected area.
- **In-canvas auto-`@`** — handwrite "@…", pause ~1.5s, and the new strokes are read and run
  automatically (Vision first; escalates "@-shaped" misreads to Claude). A blue scan-sweep animates over
  the words; ink is never erased. Settings toggle (default on).
- **Deterministic engines (COMPUTE)** via the `@`-command bar: `@balance`, `@molar`, `@units`,
  `@transcribe`, `@punnett`, `@check` (red-pen tutor), `@differentiate` — on the real engines.
- **Socratic tutor** — lasso a problem + your working → **Tutor** (lasso menu or `＋`). The red pen
  (`checkChain`) decides what's wrong; the proxy's `POST /tutor` (Claude Opus 5.5, low effort) only talks,
  one rung of a hint ladder at a time (nudge → question about the line → concept → worked example of a
  *different* problem), climbing only when the student asks. Every reply passes an **answer-leak guard**
  twice — numerically on the proxy, exactly with the engine on the device — and falls back to a math-free
  hint rather than ever showing the answer or the corrected step. Reply by writing next to the problem
  (read after a pause; any step you write is checked by the red pen, and a verified fix is passed to the
  tutor as a correction) or with the note's **Reply** button. The tutor lives in one **margin note** beside
  the line it's about, with earlier messages folded away; undo rewinds the conversation a message at a
  time. ⚠️ Needs the moderation safeguard before minors use it.
- **Generative make-real** — `@<anything>` generates a live widget via Claude (`claude-opus-4-8`,
  `max_tokens` 8192 → one pass, no truncation round-trips), rendered in a locked-down sandboxed
  **WKWebView** (CSP `default-src 'none'`, no network, navigation/`window.open` denied). A
  **"Designing…" animation** holds the widget's spot on the canvas while it generates (only on the page
  it will land on). The model picks a **card shape** for the content — portrait 360×540, landscape
  560×360 or square 440×440 — and the card is sized to match; the layout is responsive, so resizing the
  card reflows it. Only the HTML document is kept (any stray preamble / ```` ``` ```` fences are stripped
  on the server *and* in the app), and the CSP is always placed ahead of the widget's own markup. The
  card's header shows the widget's `<title>`. A generation is capped at 170s on the server; failures say
  what happened (timed out, declined, offline, server unreachable). There is no fake fallback widget
  when the server is down — the request fails with a clear reason.
- **Write-on-a-widget** — a Pencil ink layer above each generated widget (Pencil draws / finger operates
  the widget; an `✏️` header toggle enables finger-draw in the Simulator). **Erase** with the `🧽` header
  toggle (finger or Pencil rubs out whole strokes) — and a Pencil also erases when the global **Eraser**
  tool is selected, so it does to a widget exactly what it does to the page. A `ƒ` header button recognizes
  the writing (consent-gated) and feeds it to the widget via a **widget-input protocol** — generators
  expose `window.inklab.setInput(text)`, with a best-effort JS fallback for older widgets. Annotation
  strokes persist per object (a cancelled erase persists too). Generated widgets render **crisply on
  reopen** — the `WKWebView` defers its paint until it's on-screen at full size/scale, so it never
  rasterizes blurry off-screen.
- **Fit a hand-drawn graph (`@`-free, native)** — the toolbar **Fit** button (`chart.xyaxis.line`)
  samples a lassoed sketch and runs **`InkLabFit`**'s exact least squares across
  linear/quadratic/cubic/exp/power, picks the best by R² with a complexity penalty, and drops a native
  deterministic **FitGraphView** drawing the points + best-fit curve + equation + R². On-device, no OCR,
  no cloud, no consent gate — correct by construction. (A freehand sketch has no axes, so coefficients
  are in the sketch's own normalized units; the trustworthy outputs are the model *type*, the curve,
  and R².)
- **Object editing chrome** — delete (✕), resize grip (reflows generated widgets; on widget cards it
  sits in its own footer bar so it never covers the widget's controls), double-tap a sticky to edit text
  inline — all undoable via the journal. The native calculator is in the `＋` menu.
- **Lasso that coexists with navigation** — two-finger scroll and page-swipe work while the lasso tool
  is active (the lasso captures only single-finger touches); the dashed marquee persists as a closed
  loop, and handwriting strokes are hit-tested so lassoing ink reports honestly.
- **Lasso = direct manipulation** (ADR 0005) — select a mix of **handwriting + objects** and **drag from
  inside** to move it; **delete / cut / copy / paste** via a native edit menu and `⌘C/⌘X/⌘V`. Each is
  **one undo step** (objects = one journal transaction, ink reversed together). Copy/paste use a static
  session clipboard, so paste works **across pages and notebooks**, landing at the visible center with the
  set's relative layout preserved and auto-selected to drag immediately. Recognize / Check / Fit are also
  on the selection menu. (Group **resize/rotate** still deferred.)
- **Home library** — uniform, slightly **elevated** notebook covers (one generic design for every
  notebook, regardless of paper type), **drag-to-reorder** (persisted), **recolorable** (curated swatches +
  custom color picker, persisted), and **renameable** (long-press).
- **Toolbar / dock** — inline **color + thickness** shown contextually (pen/highlighter only), as two
  **independent** controls (picking a color never changes the chosen thickness); **thicker pens** (3/6/10);
  per-tool **saved colors** in a **fixed-width horizontal scroller** (tap to apply colour only, `＋` to save
  the live colour, long-press to delete) so adding many colours scrolls instead of overflowing the dock; the
  less-frequent actions (Recognize / Check / Fit / Paper) live in a `＋` **Insert/Actions** menu. The dock is
  **repositionable** (drag a grip) and **collapsible** (folds to a puck), and honors the left-handed setting.
  The drag is now **glide-smooth** — it's tracked in **global** coordinates and moved with `.position`, so the
  dock can't chase its own movement (the old `.local`-space drag + `.offset` was a feedback loop that
  vibrated). And it's **edge-aware**: dragged to either **side wall** it snaps flush and **reflows vertical**
  (an `AnyLayout` horizontal↔vertical swap); dropped anywhere else it floats as a horizontal capsule — works
  identically in both orientations. Both the position and the placement persist as **fractions of the
  container**, so they survive rotation and split-view.
- **Draw-and-hold shape snapping** — draw a line/shape and hold the pencil still ~0.5s and it snaps to a
  clean form (line — incl. snap-to-horizontal/vertical — arrow, circle/ellipse, rectangle/square, triangle/
  polygon). Deterministic + correct-or-silent (`InkLabCanvasCore` `ShapeRecognition`); one undo reverts to
  your freehand sketch. Settings toggle "Snap shapes on hold" (on by default).
- **Persistence** — the journal now writes to disk (an append-only JSONL op log + per-page `PKDrawing`
  ink blobs under Application Support, per notebook), background-flushed on suspend with
  locked-device file protection + fsync (never-lose-ink). On launch it replays the op log and reseeds
  the HLC clock; the notebook list persists (`library.json`) and relaunch **reopens the last-viewed
  page** (not always page 1). Undo/redo stacks are session-only by design.

**Not yet:** the consent/age/reachability surface (the app sends a hardcoded adult/consented/online
session, and the consent settings themselves are still in-memory — only the notebook list + journal/ink
persist), GRDB/CloudKit (the on-disk store works behind a `JournalStorage` protocol but the GRDB impl,
op-log compaction, and sync are still to come), and MyScript on-device recognition (deferred — needs a
paid license + binary SDK). **`InkLabMultiRep`** (equation↔table↔graph sync) and **`InkLabReactive`**
(spreadsheet recompute) are built + tested as packages but not yet wired into the app UI. See **Next**
below.

**→ See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the whole system at a glance (package map, pipeline, path to ship).**

## Decisions so far

| # | Decision | Where |
|---|---|---|
| Recognition provider | MyScript (on-device math) · Apple Vision (text) · Claude vision (cloud fallback + chem/diagrams), behind a swappable interface; **spike-gated**. *Vision + Claude live today; MyScript deferred.* | [ADR 0001](docs/decisions/0001-recognition-provider.md) |
| Minors + cloud-AI | **Policy A** — cloud + verifiable parental consent, on-device-only fallback when absent | [ADR 0002](docs/decisions/0002-minors-cloud-compliance.md) |
| iPadOS floor + backend | **iPadOS 18** floor; all Claude calls via a server-side proxy | [ADR 0003](docs/decisions/0003-ipados-floor-and-backend-proxy.md) |
| Object model + persistence | **Event-sourced op-log** ("journal") — global undo, never-lose-ink, rewrite-free collab; core built & tested | [ADR 0004](docs/decisions/0004-object-model.md) |
| Canvas rendering | **PKCanvasView-hosted hybrid** — native ink/zoom + object overlay; geometry core built & tested, device-gated | [ADR 0005](docs/decisions/0005-canvas-rendering.md) |
| Backup & sync | **Serverless** — Files/iCloud-Drive export now, **CloudKit** sync next; data stays in the user's own iCloud, **never on our server** (keeps minors' data out of our custody) | [ADR 0006](docs/decisions/0006-backup-and-sync.md) |

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
  decisions/              ADRs 0001–0006.
  red-pen-tutor.md, recognition-spike-plan.md, compliance-checklist.md
```

The iPad app target (`InkLab/InkLab.xcodeproj`) consumes these through `InkLabKit`, with all 12 engine
packages also wired in as direct, browsable local references. See **[How to run](#how-to-run)**.

## Build & test

The 12 pure-Swift library packages (145 tests total) run on the CLI without an iPad:
```sh
( cd Packages/InkLabRecognition && swift test )    # 9 tests — recognition routing/consent
( cd Packages/InkLabDoc         && swift test )    # 10 tests — the journal (incl. setObjectState/promote undo)
( cd Packages/InkLabMath        && swift test )    # 32 tests — the red pen (algebra + calculus) + the tutor's leak guard
( cd Packages/InkLabUnits       && swift test )    # the dimensional conscience
( cd Packages/InkLabChem        && swift test )    # chemistry (balancing + molar mass)
( cd Packages/InkLabBio         && swift test )    # biology (genetics + sequences)
( cd Packages/InkLabCanvasCore  && swift test )    # 25 tests — canvas geometry (lasso/transform/paging) + draw-and-hold shape recognition
( cd Packages/InkLabReactive    && swift test )    # reactive worked-solutions
( cd Packages/InkLabFit         && swift test )    # lab-notebook curve fitting
( cd Packages/InkLabMultiRep    && swift test )    # linked multi-representation
( cd Packages/InkLabRouter      && swift test )    # intent router + @ ask-marker
( cd Packages/InkLabSearch      && swift test )    # notebook search
# + Packages/InkLabKit — umbrella that re-exports all of the above
```

Requires Swift 6 (Xcode 26+). The packages are intentionally Foundation-only so their logic is
testable without an iPad. The iPad app provides the PencilKit adapter (`PKStroke`→`InkStroke`,
`PKDrawing`→`RasterImage`/`BlobRef`), the Vision/Claude recognizers + make-real providers, and the
sandboxed WKWebView host. (The GRDB local store + `CKSyncEngine` transport for `InkLabDoc` and the
MyScript bridge are still to come.)

## How to run

**Clone** the public repo:
```sh
git clone https://github.com/ryanrudat/InkLab.git
cd InkLab
```
You need **Xcode 26+** (Swift 6, iOS/iPadOS 18 SDK) for the app and **Node 24.12+** for
the backend proxy. `Server/.nvmrc` pins the current Node 24 LTS release used by CI.

1. **Backend proxy** — install the locked development tools, copy the secret-free environment
   template, and paste your Anthropic key into the new gitignored `Server/.env`:
   ```sh
   cd Server
   nvm use
   npm ci
   cp .env.example .env
   npm run check
   npm start                       # auto-loads .env; proxy on :8787
   ```
   The model id is `claude-opus-4-8`. Verified live end-to-end: `/health`, `/make-real` (generates a
   real widget), and `/recognize` (reads "@a clock" at 0.97 confidence).
2. **The app** — open `InkLab/InkLab.xcodeproj` in Xcode and **Run on an iPadOS 18+ simulator**.
   The tracked, secret-free `InkLab/Info.plist` is ready for `localhost` and permits local networking.
   For a real iPad or deployed proxy, create ignored local overrides, then edit only
   `Info.local.plist`:
   ```sh
   cp InkLab/Info.plist InkLab/Info.local.plist
   cp InkLab/Secrets.xcconfig.example InkLab/Secrets.xcconfig
   ```
   Set `MakeRealBaseURL` to the Mac's LAN URL or deployed HTTPS URL and set
   `MakeRealProxySecret` when the proxy requires it. These local files remain untracked.

The app target builds **only in Xcode** (needs the iOS SDK). It depends on the **`InkLabKit`** umbrella
package (`Packages/InkLabKit`), which re-exports every library — so the app just writes
`import InkLabKit`; all 12 engine packages are also wired in as direct, browsable local references.
Canvas code lives in `InkLab/InkLab/` (`CanvasViewController`, `ObjectOverlayView`, `ObjectHostView`,
`WebWidgetView`, `WidgetAnnotationView`, `FitGraph`/`FitGraphView`, `JournalStore`,
`JournalStorage`, `PencilKitAdapters`).

## Backend proxy (`Server/`)

All Anthropic calls go through a server-side proxy (ADR 0002) — the iPad never holds the API key. It
enforces the consent/age gate, runs the make-real multi-pass assembler, and validates model output
(correct-or-silent; the regex widget-HTML validator is defense-in-depth — the WKWebView lockdown is the
real boundary). TypeScript runs directly on Node 24.12+ using stable native type stripping (no build
step), while `tsc` performs a separate strict check:
```sh
cd Server && npm run check                     # strict type-check + 85 offline tests
cd Server && npm run mock                      # the real server with a scripted fake Claude, on :8799
```
The key is read from `Server/.env` (`ANTHROPIC_API_KEY=…`); `npm start` auto-loads it — see
**[How to run](#how-to-run)** above. See [Server/README.md](Server/README.md).

The mock proxy is for Simulator UI runs without a key: a Debug build reads `INKLAB_PROXY_URL` from its
environment, so `TutorFlowShot` (and `SIMCTL_CHILD_INKLAB_PROXY_URL=http://localhost:8799 xcrun simctl
launch …`) point the app at it without touching the plist. `TutorFlowShot` skips itself when the mock
isn't running.

## Next (current to-do)

The app runs end-to-end against the live proxy; the gaps that block real-world use:

- **Consent / compliance surface** — real age screen + App-Store §5.1.2(i) third-party-AI permission +
  `NWPathMonitor` reachability feeding a real `SessionContext` (the app currently sends a hardcoded
  adult/consented/online session). Required before any cloud use by minors. See
  [docs/compliance-checklist.md](docs/compliance-checklist.md).
- **Persistence** — the file-backed store (JSONL op log + ink blobs) ships behind a `JournalStorage`
  protocol and survives relaunch; still to do: the **GRDB** local impl (swap behind the protocol),
  **op-log compaction**, then CloudKit / `CKSyncEngine` sync (re-validate widget HTML received from
  another device before loading). Consent settings are still in-memory (reset each launch) — only the
  notebook list + journal/ink persist.
- **Backup & restore (ADR 0006)** — there is **no backup today**, so deleting the app loses notebooks (a
  user hit this). Ship a **Files / iCloud-Drive export+import** first (survives app deletion), then the
  CloudKit sync above. **Serverless by design — notebooks never go on our server** (the Railway proxy stays
  stateless; storing minors' ink there would break the privacy/compliance posture).
- **MyScript on-device recognition** (needs a paid license + binary SDK) for dependable offline
  handwriting/math; run the recognition spike on real messy student math
  ([docs/recognition-spike-plan.md](docs/recognition-spike-plan.md)). Structured math
  (exponents/fractions) needs MyScript or a structured provider — Vision/Claude return flat text here.
- **Server hardening** — real input/output moderation (Organizations-Serving-Minors), auth, rate
  limiting, deploy, ZDR + data minimization.
- **Perf** — many live WKWebViews each run as a separate process; want static-raster default, lazy load
  on selection, LRU eviction, heavy setup off the ink run-loop.
- **Make-real polish** — token-by-token streaming (a "Designing…" placeholder already animates in place
  during generation, and the widget now drops exactly where that placeholder was), sticker↔interactive↔3D
  promotion UI (the journal `promote` op exists; no UI yet), editable generated widgets. The WKWebView
  is a *renderer* so far — its CSP now allows `script-src 'unsafe-eval'` so graphers/calculators can
  evaluate a user-typed expression (network isolation, not eval, is the real boundary) — but the §6
  interpreters' bundled JS engines (math.js/three.js/RDKit.js/ngspice-wasm) aren't bundled yet.
- **Remaining §6 interpreters** — draw→sticker + tray, 2D→3D, executable circuits, reactive knobs
  (`InkLabReactive`), linked multi-representation (`InkLabMultiRep`), proof hints — engines exist for
  several; UI not wired. *(Bring-to-life curve fitting via `InkLabFit` is now wired — see the Fit
  button above.)*
- **Around the canvas** — paging/continuous scroll (§5.2), page-overview, Search UI (`InkLabSearch`
  exists), Study hub, onboarding/empty state; object/group **rotate** and group **resize**. *(Lasso move
  and cut/copy/paste across pages & notebooks are now shipped — see "Lasso = direct manipulation" above.)*
- **ADR-0005 device gates** (zoom crispness/overlay registration, palm rejection, GPU memory, ink
  round-trip) and an **accessibility pass** (VoiceOver into generated WKWebView widgets is unsolved) —
  both need a physical iPad.

Foundational/irreversible choices are proposed with trade-offs before broad implementation (brief §0).
