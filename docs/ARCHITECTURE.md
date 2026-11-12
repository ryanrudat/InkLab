# InkLab — Architecture & Roadmap

One page tying the whole system together. For the *why* behind each decision see the ADRs in
[docs/decisions/](decisions/).

## As-built (2026-06-07)
The first end-to-end vertical slice now runs on an iPadOS 18 Simulator: handwrite/type an "@"
command → recognize → dispatch → live object on the canvas → recorded in the journal. What is
actually wired:

**Foundation / wiring**
- Fixed a pre-existing crash that prevented *any* notebook from opening (the lasso gesture was used
  before it was created); the gesture is now created eagerly.
- App deployment target lowered to **iPadOS 18.0** (matches the ADR 0003 floor; the previous 26.4
  target blocked install on most iPads/simulators).
- All 12 engine packages are now **direct local Swift Package references** in
  `InkLab.xcodeproj` (previously only the `InkLabKit` umbrella was referenced and the rest came in
  transitively); all are linked and browsable.
- Canvas is drawable in the Simulator: `PKCanvasView.drawingPolicy = .anyInput` plus a Settings
  toggle "Finger / mouse drawing" (default on; turn off on iPad for pencil-draws / finger-navigates).
  The `canvasViewDrawingDidChange` delegate is wired.

**Recognition (READ side) — as built**
- **Apple Vision on-device** recognizer (`VisionTextRecognizer`) implemented in the *app* target so
  the `InkLabRecognition` package stays Foundation-pure. Reads flat text; works offline/free.
- **Claude vision via the proxy** (`ClaudeVisionRecognizer`): app → Server `POST /recognize` →
  Claude vision. Verified live reading "@a clock" at 0.97 confidence.
- **Why both:** Apple Vision misreads a handwritten "@" as "a"; Claude reads "@" correctly. The
  Recognize button therefore uses **Claude**, with Apple Vision as the offline/free fallback. A
  "Read as…" review sheet shows the (editable) transcription plus engine chips. Lasso-region
  recognition reads only the lassoed area.
- These return **flat text** — structured math (exponents/fractions) needs MyScript or a structured
  provider. **MyScript is not integrated** (needs a paid license + binary SDK) — deferred.

**Deterministic engines (COMPUTE side) — now reachable in the app**
- The "@" command bar runs the real engines via shared routing in `CommandRunner`/`EngineKit`:
  `@balance`, `@molar` (the router previously never emitted it — fixed), `@units`, `@transcribe`,
  `@punnett`, `@check` (red-pen tutor via `InkLabMath` `checkChain`), `@differentiate`. Engine chips
  also appear on the recognition review sheet.

**Make-real (generate live objects) — the headline feature**
- **Router → engine OR generative Claude → live object.** Deterministic verbs stay on the exact
  engines (READ vs COMPUTE); `@<anything>` else generates a live widget via Claude. Verified live:
  "@scientific calculator" produced a working calculator that fits the card.
- **Journal (`InkLabDoc`)** gained two *additive* ops — `setObjectState` (edit a widget/chart/3D's
  inline state) and `promote` (energy-level swap) — both one-step-undoable, with fold/invert/remap
  arms and tests (`test_G`/`test_G2`). Existing case serialization is unchanged.
- **Polymorphic live-object host** (`ObjectOverlayView`/`ObjectHostView`) renders text cards
  (sticky/recognized/callout), native widgets, AND a locked-down `WKWebView`; it rebuilds in place
  when an object's payload *kind* changes.
- **`WebWidgetView`**: a locked-down `WKWebView` sandbox (CSP `default-src 'none'`, no network,
  navigation cancelled, `window.open` denied, non-persistent store) — renders generated HTML safely
  on a minor's device. This sandbox is currently a **renderer only**; the bundled JS engines for the
  §6 interpreters are not bundled yet.
- **`MakeRealProvider`** protocol; the default (and only) provider is `ProxyMakeRealProvider` (Server
  `/make-real` → Claude multi-pass assembler), returning the HTML plus its card `layout`. The stub/auto
  fallback was removed — an unreachable server fails with a clear reason instead of a fake widget.
- **Widget sizing:** the model declares a card shape (`<meta name="inklab-layout">`: portrait 360×540,
  landscape 560×360, square 440×440) and designs a responsive layout for it; the card adds a 28pt header and
  a 22pt footer (resize grip) around that content area (`WidgetCard`). The app strips stray model text and
  places the CSP as the first element after a standards-mode doctype (`WidgetHTML.sandboxedDocument`).
- A **native scientific calculator** (Tier A, `InkLabMath`-backed, correct-or-silent) exists to prove
  the substrate but is **not** the default path (generative is) — kept as the "known → native" option.

**In-canvas "@" ask-marker**
- Handwrite "@…" and pause ~1.5s → the *new* strokes are read and, if they form an "@" command, it
  runs **automatically** (no Recognize tap). Auto-scan tries Apple Vision first (free); a short
  "@-shaped" misread escalates that batch to Claude (which reads "@"). Settings toggle "Auto-run @
  commands" (default on). A blue "reading" scan-sweep plays during recognition. Ink is never erased
  (never-lose-ink); the result appears alongside.

**Object editing chrome (all undoable via the journal)**
- Delete ✕ (top-right) on every object; undo restores (delete/restore ops).
- Resize grip (bottom-right) — drag to resize; generated-widget content reflows; commits a
  `setTransform`.
- Double-tap a sticky note → edit text inline (Done bar above the keyboard); commits `setProps`;
  undo reverts.

**Cloud setup (Claude API)**
- Server reads `ANTHROPIC_API_KEY` from `Server/.env`; `npm start` auto-loads it
  (`node --env-file-if-exists=.env`). `.env` is gitignored and created from `.env.example`.
- App reaches the local server over HTTP via Info.plist `NSAppTransportSecurity` →
  `NSAllowsLocalNetworking` (kept `GENERATE_INFOPLIST_FILE`; `INFOPLIST_FILE=Info.plist` merges).
- Model id `claude-opus-4-8` (confirmed current). A real key verified end-to-end: `/health` ok,
  `/make-real` generated a real widget, `/recognize` read "@a clock".
- Robustness: in-flight guard (no overlapping generations), 90s network timeout, auto-fallback to the
  on-device stub when the server is down.

**Tests / verification (this session)**
- App: 16 unit tests (engine routing incl. the `@molar` fix, calculator-via-engine, widget
  insert+edit+undo, object delete+undo, sticky text edit+undo, differentiate-parenthesization,
  Vision-reads-rendered-text incl. "@") plus UI tests (make-real on page, sticky chrome, sticky
  edit). `InkLabDoc` package: 9 tests (incl. `setObjectState`/`promote` one-step undo). Builds and
  runs on an iPadOS 18 Simulator.

**Still pending (highlights — full list in "Path to ship" below)**
- **Consent/compliance surface:** the app currently sends a **hardcoded** adult/consented/online
  session. A real age screen + App Store §5.1.2(i) third-party-AI permission + `NWPathMonitor`
  reachability feeding a real `SessionContext` are **required before any cloud use by minors**.
- **MyScript** on-device recognition (paid license + binary SDK) for dependable offline
  handwriting/structured math; run the recognition spike on real messy student math.
- **Perf:** many live `WKWebView`s (each its own process) — needs static-raster default, lazy load on
  selection, LRU eviction, keep heavy setup off the ink run-loop.

## As-built (2026-06-08)
Building on the 2026-06-07 slice. Six things shipped today:

**Persistence — the journal now survives relaunch (ADR 0004 as-built)**
- New `JournalStorage` protocol (`InkLab/InkLab/JournalStorage.swift`) with a file-backed impl
  `FileJournalStorage`: an **append-only JSONL op log** (`oplog.jsonl`, one JSON-encoded `Op` per
  line) plus **per-page `PKDrawing` ink blobs** (`ink/<page>.drawing`), scoped per notebook under
  Application Support. GRDB-ready (a GRDB/SQLite impl drops in behind the same protocol later;
  **GRDB not built yet**).
- On launch the op log is **replayed via `fold`** and the HLC `Clock` is reseeded past the loaded
  ops. The notebook **list** persists too (`Library` → `library.json`; `Notebook` is `Codable` with a
  **stable id**) so each notebook's storage dir is stable. Background-flush on suspend
  (never-lose-ink), locked-device `FileProtection` (`completeUntilFirstUserAuthentication`), `fsync`.
- Relaunch **reopens the last-viewed page** (UserDefaults per notebook), not always page 1.
  Undo/redo stacks are **session-only by design**. Tests: `journalPersistsAndReloads`,
  `reloadReopensLastViewedPage`, `persistedUndoSurvivesReloadHistoryResets`.
- **Still TODO:** the GRDB impl, op-log compaction, CloudKit sync. Consent/age settings are **not**
  persisted (see caveat below).

**Lasso fixes (ADR 0005)**
- Two-finger scroll + page-swipe now work while the lasso tool is active
  (`lassoGesture.maximumNumberOfTouches = 1`; `ObjectOverlayView.hitTest` only captures single-finger
  touches). The dashed marquee persists as a **closed loop** until invalidated. Ink strokes are
  hit-tested (`strokeHitTest`) so lassoing handwriting reports honestly. Lasso points and stroke
  points already share content coords (`overlay.bounds.origin == contentOffset`) — no
  `adjustedContentInset` conversion needed.

**Make-real polish**
- Model `claude-opus-4-8`, `maxTokens` **8192** — one pass, no truncation round-trips. A
  **"Designing…" animation** (`DesigningPlaceholderView`) shows on the canvas where the widget will
  land while it generates (hidden while another page is showing).

**Widget sandbox (ADR 0002 / 0005)**
- `WebWidgetView` CSP now allows `script-src 'unsafe-eval'` (alongside `'unsafe-inline'`) so
  graphers/calculators can evaluate a user-typed expression (a CSP "Refused to evaluate a string as
  JavaScript" error previously broke them). **Safe** because the real boundary is **network
  isolation** (`default-src 'none'` + `baseURL` nil + nav-delegate cancels navigation + server
  validator blocks external/`fetch`/`iframe`) — `eval` can't reach the network or escape the card.
  CSP is injected at render time (fixes already-generated widgets).

**Write on a widget — annotate + erase + handwrite-to-plot**
- `WidgetAnnotationView` is an ink layer **above** each generated widget: Pencil draws / finger
  operates the widget, plus a ✏️ header toggle for finger-draw (the Simulator has no Pencil).
- **Erase (2026-06-22):** a 🧽 header toggle rubs out whole strokes with finger or Pencil
  (point-to-segment distance; mutually exclusive with ✏️; header tints red), and a Pencil also erases
  whenever the app's global **Eraser** tool is active — `pencilErases` is propagated
  `CanvasViewController.apply → ObjectOverlayView.setPencilErasesAnnotations → ObjectHostView →
  WidgetAnnotationView`. This also fixed a latent bug (the Eraser tool used to *draw* on widgets). A
  *cancelled* erase still persists (`touchesCancelled` fires `onChanged`), so rubbed-out ink can't
  resurrect from the stale on-disk blob.
- A ƒ header button **recognizes** the writing (consent-gated, same recognizer as the Recognize button)
  and feeds it to the widget via a new **widget input protocol**: the generator prompt now asks
  widgets to expose `window.inklab.setInput(text)`; `WebWidgetView.setInput` calls it with a
  best-effort JS fallback (fill first input + click a plot/compute button) for older widgets.
  Annotation strokes persist per object. **Needs an on-device pass** (Pencil-vs-finger routing can't
  be tested in the Simulator).
- **Crisp render on reopen (2026-06-22):** `WebWidgetView` defers `loadHTMLString` to `loadIfReady()`
  (gated on `window != nil && bounds > 1`, via `didMoveToWindow` + `layoutSubviews`), holding the HTML
  in `pendingHTML`. `viewDidLoad` rebuilds every object before the canvas is in a window/laid out, so a
  synchronous load painted the `WKWebView` once off-screen at zero-size/1× and stayed blurry until a
  drag re-composited it. Deferring makes the single paint land on the real screen at full resolution.

**Curve fitting — `InkLabFit` wired into the app ("bring a hand-drawn graph to life")**
- Toolbar **Fit** button (SF Symbol `chart.xyaxis.line`) → `CanvasViewController.fitLassoedSketch()`
  samples the lassoed stroke points → `CurveFitter` (`InkLab/InkLab/FitGraph.swift`) tries
  linear/quadratic/cubic/exp/power via `InkLabFit`'s **exact least-squares**, recomputes R² in data
  space for a fair comparison, and picks the best by **(R² − 0.02·params)** (complexity penalty →
  prefer the simpler model) → drops a **native deterministic** `FitGraphView` (`native:fitGraph`
  widget) drawing the points + best-fit curve + equation + R². On-device, **no OCR, no cloud, no
  consent gate — correct by construction.** Caveat: a freehand sketch has no axes, so coefficients
  are in the sketch's own normalized units (x scaled to 0–10); the trustworthy outputs are the model
  **type**, the curve, and **R²**. Test: `curveFitterClassifiesSketchShape`.

**Engine wiring status (2026-06-08):** wired into the app — `InkLabMath` (Check working,
Differentiate), `InkLabUnits` (Units), `InkLabChem` (Balance, Molar mass), `InkLabBio` (DNA→Protein,
Punnett), and now `InkLabFit` (Fit). **Not yet wired** into the app UI: `InkLabMultiRep`
(equation↔table↔graph sync) and `InkLabReactive` (spreadsheet recompute) — built + tested as
packages but unsurfaced. `InkLabRouter`/`InkLabSearch` are used internally.

**Tests (2026-06-08):** app `InkLabTests` = **23** passing (incl. the three persistence tests and
`curveFitterClassifiesSketchShape`); backend `Server` = **19**; `InkLabDoc` = **9**. Other engine
packages unchanged from the baseline.

**Caveats (do not overclaim):** Railway hosting is **interim** (revisit before publication — data
residency for minors, ZDR). `AppSettings` consent (the cloud-AI opt-in + `userKind`/`ageVerified`)
is **still in-memory and resets each launch** — only the notebook list + journal/ink persist, **not**
the consent settings. A real age-gate / §5.1.2(i) first-run consent UI is **still TODO**. The
MyScript spike is **still deferred**; the interim recognizer is Apple Vision on-device + Claude
vision via the proxy, behind the `InkRecognizer` protocol.

## As-built (2026-06-09)
Building on the 2026-06-08 slice. Four threads shipped today (all built + verified on an iPadOS 18
Simulator — library packages + backend on the CLI, app build + unit/UI tests on the Simulator).

**Correctness/safety hardening (a multi-agent bug hunt, each finding adversarially re-verified)**
- **CRITICAL — server consent gate was FAIL-OPEN; now FAIL-CLOSED.** `Server/src/consent.ts`
  `cloudEligible` only blocked the literal `userKind === 'minorUnconsented'`; any typo'd / tampered /
  missing / unknown `userKind` (the session is untrusted JSON, validated nowhere) fell through to
  *allowed* — so a minor's ink could reach Anthropic. It now validates the session **shape** at
  runtime and **whitelists** only known-eligible kinds (adult / minorConsented / schoolManaged, with
  `ageVerified`), defaulting to **blocked**. New tests. (The Swift `DefaultCloudPolicy` still omits the
  `ageVerified` safeguard — LOW / dead-code today since the app gates via `MakeRealSession.blockReason`,
  which does check it — align if `RoutingRecognizer` is ever wired for minors.)
- **Engines degrade instead of crashing (correct-or-silent upheld).** `InkLabMath`
  (Rational/Polynomial/`intPow` + the `Expr` tokenizer) and `InkLabChem` (`Frac` + the RREF balancer)
  used trapping `Int`, so `@check 2^100`, a long decimal, or a big `@balance` `SIGTRAP`'d the process.
  They now use **checked arithmetic with an absorbing overflow sentinel** — the red-pen tutor degrades
  to `.unsupported`, the balancer to `.cannotBalance` (also fixed a latent `Rational` ÷0 trap).
- **`numericValue` is now finite-or-nil.** It used to return a non-nil `NaN` for an undefined domain
  (e.g. `(-2)^0.5`, no `.pow` guard), which passed `guard let value` in `InkLabReactive`/`InkLabMultiRep`
  → "success" with a `NaN` that corrupted the sheet / curve-fit. MultiRep now also filters non-finite
  samples and disqualifies `NaN`-R² candidates; `InkLabFit` `rSquared` clamps non-finite.
- **`@transcribe` / `@translate` fixed** — both used to call DNA→protein; now `@transcribe` = DNA→mRNA
  and `@translate` = mRNA→protein (the correct `InkLabBio` functions).
- **Op-log + clock integrity.** The HLC `Clock.tick()` wrapping `UInt16` counter never advanced the
  wall within a session (total order corrupted after 65,536 ops); it now advances the wall on counter
  overflow (strictly monotonic). `FileJournalStorage.loadOps` silently dropped any unreadable line
  (an interior corrupt op left a replay **hole**); it now distinguishes a benign torn tail from
  interior corruption (logged loudly). `JournalStorage.append`/`JournalStore` are now **throwing** so a
  real persistence failure is **surfaced** (an `onPersistenceError` hook) instead of silently swallowed.
- **Canvas async/page races** — auto-"@" scan and async make-real / Check / Recognize results could
  land on the **wrong page** after a page switch; the originating page is now captured and guarded, and
  a pending auto-scan is cancelled on a page switch. A transform-only update to a **native** widget now
  uses a geometry-only path (`applyGeometry`) instead of reloading journaled state (which wiped
  uncommitted calculator input).
- **`InkLabFit` exp/power fits were dead code** (zero-baseline normalization made the positivity gate
  always fail) — normalization now uses a small positive floor so those models are reachable.
- **`InkLabSearch` snippet** crashed on length-changing lowercasing (e.g. Turkish "İ") because it mixed
  `String.Index` from `text.lowercased()` into the original text; it now matches the original
  case-insensitively.
- **Proxy stopped leaking internals** — it returned raw exceptions and the verbatim upstream Anthropic
  error body (incl. `request_id`); errors are now generic (500 "internal error" / 502 "upstream error")
  and `anthropic.ts` no longer embeds the upstream body. Plus a request **body-size cap** (8 MB → 413),
  **400** on malformed/missing JSON (was a 500), a broadened `validateWidgetHtml`
  (img / `<meta refresh>` / `<base>` / `sendBeacon` / WebSocket / EventSource / dynamic `import()` /
  css `url()` / protocol-relative `//`; its comment corrected to note the on-device `WKWebView` CSP is
  the real boundary), and `stripMarker` now removes only the **trailing** DONE marker.
- **Still open (documented):** the `fold(_:from:)` compaction high-water trap (unreachable today — no
  compaction store wired; fix before GRDB/compaction). _(The `isRestoringDrawing` PencilKit delegate-timing
  fragility flagged here was **fixed 2026-06-18** — see the as-built undo bullet below.)_ Regression tests
  added across the above.

**Lasso is now direct manipulation (ADR 0005 — move + edit shipped)**
- **Move:** select a mix of **handwriting + objects** and drag from inside the selection. Objects move
  as **one journal transaction** (`setTransform` × n); ink translates via `PKStroke.transform` (rebuilt
  `PKDrawing`); a mixed move is **one undo step** via a combined journal/ink history step.
- **Delete / Cut / Copy / Paste** via a native edit menu (tap inside the selection) + ⌘C/⌘X/⌘V — each
  one undo step via a generalized `HistoryStep.compound` + `commitCompound` (objects = one journal
  transaction, ink = before→after drawing, reversed together). Copy/paste use a **static session
  clipboard**, so paste works **across pages and notebooks**; paste lands at the visible center
  preserving the copied set's relative layout and is auto-selected so it can be dragged immediately.
- **Recognize / Check / Fit** added to the lasso selection menu (they act on the selection). A tap on
  an object's ✕ delete now passes through even in lasso mode (the overlay used to swallow it). Group
  **resize/rotate is still deferred.**

**Home library redesign**
- Uniform, slightly-**elevated** notebook covers — one generic design for every notebook (darker spine,
  soft depth gradient, title on a label plaque, soft drop shadow), identical regardless of paper type.
- Notebooks are now **drag-to-reorder** (persisted), **recolorable** (curated swatches + a custom system
  color picker, persisted), and **renameable** (long-press menu). Screenshot-verified on the Simulator.

**Toolbar / "dock" redesign** (researched GoodNotes 6 / Notability / Noteshelf 3 / Apple
Notes-PencilKit / OneNote / Samsung Notes)
- **Phase 1** — inline color + thickness shown **contextually** (only for pen/highlighter); the
  less-frequent actions (Recognize / Check / Fit / Paper) moved into a "＋" Insert/Actions menu.
- **Phase 2** — **pen favorites/presets**: saved (color + width) pens **per tool**, persisted
  (UserDefaults); tap a chip to apply both, long-press to edit, a dashed ＋ to save the live pen.
- **Phase 3** — the dock is **repositionable** (drag a grip; clamped on-screen; position persisted) and
  **collapsible** (a chevron folds it to a puck). The "@" command button honors the `leftHanded` setting.
- **Drag-fluidity rework** (the drag stuttered): the dock is its own view; `vc.apply` is now idempotent
  (a drag no longer re-runs `updateUIViewController` and reassigns the PencilKit tool each frame); the
  clamp measures the bar so it can't slide half off-screen; toolbar content is isolated in a child view
  (`DockBar`); the always-rendered inline `UIColorWell` was replaced by a lightweight color-dot button
  that opens a popover. **Final feel best confirmed on a physical iPad.**
- **"Check working" renamed to "Check work"** everywhere it appears.

**Tests (2026-06-09):** app `InkLabTests` = **23** unit tests + UI tests; backend `Server` = **23**;
library packages = **123** total (see the Package map). Builds and runs on an iPadOS 18 Simulator.

## As-built (2026-06-16 → 17)
Writing-experience work, three canvas correctness fixes, a new shape-recognition capability, and a
backup decision. Built + Simulator-verified; the **draw-and-hold** fix was also **confirmed on a real iPad
+ Pencil**, the **undo** fix is build- + regression-test-verified (on-device pass still recommended), and
each correctness-critical change went through a multi-agent adversarial review.

- **Paper style persists.** A canvas paper change writes back to the notebook (`Library.setPaper` →
  `library.json`) instead of reverting to ruled on relaunch; Settings "Default paper" is now persisted and
  applied to new notebooks.
- **Stylus writing rework.** Bolder pens (`2/4/8 → 3/6/10`); **colour and thickness are independent** (the
  old `(colour,width)` favourites snapped the width back on a colour tap — replaced by a colour-only
  palette); saved colours sit in a **fixed-width horizontal scroller** so the dock can't overflow.
- **Lasso DRAG is smooth.** No longer rebuilds + re-renders the whole `PKDrawing` per touch-move — the
  selected strokes are lifted onto a snapshot `CALayer` translated per frame (real drawing rebuilt once on
  release), with per-frame layer mutations in a no-implicit-animation `CATransaction`.
- **Lasso SELECTION captures everything inside the loop** — the hit-test now applies `PKStroke.transform`
  (a previously-moved stroke was tested at its stale location) and samples the dense interpolated path
  (`PencilKitAdapters.hitTestPoints`) not the sparse control points.
- **Draw-and-hold SHAPE SNAPPING (new).** Hold the pencil ~0.5s after a stroke → snaps to a clean
  line/arrow/circle/ellipse/rectangle/triangle. Deterministic, correct-or-silent engine in
  `InkLabCanvasCore` (`ShapeRecognition`, **+14 tests**); one undo step (→ freehand). Detection observes
  PencilKit's own `drawingGestureRecognizer` + the finished stroke's end-dwell samples (a separate
  recognizer can't run alongside PencilKit drawing on iOS 18). Settings toggle "Snap shapes on hold".
- **Undo no longer resurrects ink (real fix 2026-06-18).** Root cause: assigning `canvasView.drawing`
  commits through PencilKit's **async render pipeline** (devforums 702903/719944), so for a window the
  canvas's live stroke base is still the pre-swap drawing and the next stroke is composited onto it —
  re-introducing the removed stroke. (A 06-17 attempt that only gated input + cleared PencilKit's
  `UndoManager` did **not** hold.) `setCanvasDrawing` now records the **content-signature** of every removed
  stroke and `canvasViewDrawingDidChange` **strips any that reappear** — structurally race-proof, leaving
  bitmap-eraser and redo untouched. Note: `PKDrawing.dataRepresentation()` is **not** byte-stable for
  identical content, so it can't be a stroke identity — signatures hash the stroke's geometry+ink via a
  process-stable `Hasher`. Test `resurrectedStrokesAreStrippedByIdentity`. Closes the latent
  `isRestoringDrawing` item from 2026-06-09.
- **AI / make-real background behaviour — investigated, confirmed correct (no code change).** Generation
  is a single one-shot request; the generated widget's HTML is persisted to the op-log and **replayed from
  disk on reopen — Claude is never re-invoked**; the app requests no background execution, so closing it
  suspends the in-flight request and the widget's own JS. A ticking-clock widget is local offline JS, not
  the AI.
- **Backup decision — serverless ([ADR 0006](decisions/0006-backup-and-sync.md)).** Prompted by a real
  data loss (deleting the dev app wiped notebooks; on-device-only storage, no backup). Plan: a **Files /
  iCloud-Drive export** now, then **CloudKit** sync (the user's own iCloud). **The Railway proxy stays
  stateless — notebooks never go on our server** (would make us a custodian of minors' handwriting).

**Tests (2026-06-16):** library packages = **137** total (InkLabCanvasCore 11 → **25**, +14 shape
recognition); app `InkLabTests` = **23** + UI tests; backend `Server` = **23**. All green.

## As-built (2026-06-25)
Floating-dock rewrite (`InkLab/InkLab/CanvasScreen.swift`). The dock is its own view so moving it
never re-runs the heavy toolbar body — only its local drag/placement state changes.

- **Drag jitter fixed.** The drag is now tracked in **global** coordinates and the dock is moved with
  `.position` (was a `.local`-space `DragGesture` + `.offset` — a feedback loop where each frame's
  reported translation included the dock's own movement, so it vibrated). `.global` decouples the
  reported translation from the dock's motion → no feedback loop.
- **Edge-snapping + auto-reflow (new).** Drop the dock against either side wall and it **snaps flush
  and reflows VERTICAL** (`AnyLayout` `HStackLayout`↔`VStackLayout`, preserving child identity so it
  animates as one motion); drop it anywhere else and it floats as a **horizontal capsule**. A 48 pt
  snap zone decides; one spring (`response 0.34`, `dampingFraction 0.82`) drives both the snap and the
  post-reflow re-measure. The page-step chevrons and the saved-colour scroller follow the axis. It
  behaves identically in both orientations.
- **Persistence is rotation / split-view safe.** Center (`fx`/`fy`) and placement
  (`.floating`/`.left`/`.right`) persist as **fractions of the container** via `@AppStorage`, so a
  device rotation or Split View resize keeps the dock where it belongs. The first un-measured frame is
  hidden so a persisted edge placement can't flash mid-screen on open. The collapse-to-puck behaviour
  from the 2026-06-09 redesign is retained.

**Tests (2026-06-25):** unchanged from 2026-06-16 — library packages = **137** total; backend
`Server` = **23**; app `InkLabTests` = **24** unit tests (Swift Testing `@Test`) + UI tests. The dock
rewrite is layout/interaction-only and is best confirmed on a physical iPad. All green.

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
*As built (2026-06-07):* on-device recognition is Apple Vision; the cloud path is Claude vision via
the proxy `/recognize`; make-real renders into a locked-down `WKWebView` and is recorded in the
(currently in-memory) journal.

## The pipeline (§4.2)
`select region / @command → rasterize (+ strokes) → router classifies intent → dispatch`:
- **deterministic** → a vetted engine (`InkLabMath` solve/red-pen, `InkLabChem` balance, …)
- **native** → a vetted widget (calculator)
- **generative** → make-real via the proxy, then validated/sandboxed
→ result rendered as a live object → written to the **journal** (global undo, conflict-free merge).

*As built (2026-06-07):* this pipeline is live for the verbs listed above and for `@<anything>`
generative make-real; an in-canvas "@" ask-marker runs it automatically after a ~1.5s pause. The
journal records make-real, edits, resize, delete, and sticky-text edits (all undoable) — but it is
in-memory and ink is not yet journaled.

## Package map (all CLI-tested)
| Package | Role | Tests |
|---|---|---|
| InkLabRecognition | swappable handwriting→formal-structure routing + consent gate | 9 |
| InkLabDoc | the journal / object model (fold·invert·merge·remap) | 10 |
| InkLabCanvasCore | canvas geometry (lasso·transform·coords·paging) + draw-and-hold shape recognition | 25 |
| InkLabMath | red-pen tutor — algebra + calculus | 24 |
| InkLabUnits | dimensional conscience | 9 |
| InkLabChem | balancing + molar mass | 10 |
| InkLabBio | DNA→protein · mutations · Punnett | 8 |
| InkLabReactive | reactive worked-solutions (knob → recompute) — *built, not yet wired into the app UI* | 10 |
| InkLabFit | lab-notebook least-squares + R² + error bars — **wired into the app (Fit)** | 6 |
| InkLabMultiRep | equation ↔ table ↔ best-fit — *built, not yet wired into the app UI* | 8 |
| InkLabRouter | intent router + "@" ask-marker | 11 |
| InkLabSearch | notebook content search | 7 |
| InkLabKit | umbrella — re-exports all of the above (`import InkLabKit`) | — |
| **Library total** | 12 packages | **137** |
| Server/ (TS) | backend proxy — gate · assembler · validation | 26 |

*As built (2026-06-07):* in addition to the package tests above, the **app** now carries 16 unit
tests + UI tests, and `InkLabDoc` is at 9 tests after adding the additive `setObjectState`/`promote`
ops. App-target code (Apple Vision + Claude recognizers, the live-object host, the `WKWebView`
sandbox, make-real providers) lives in the app, not the packages, to keep the packages pure.

## Decisions (ADRs)
- **0001** Recognition: MyScript (on-device math) · Apple Vision (text) · Claude (cloud fallback + chem/diagrams), swappable; spike-gated.
- **0002** Minors/cloud: **Policy A** — cloud + verifiable parental consent; ship general-audience; backend proxy required.
- **0003** iPadOS 18 floor; all Anthropic calls via the proxy.
- **0004** Object model: event-sourced op-log ("journal").
- **0005** Canvas: PKCanvasView-hosted hybrid (native ink/zoom + object overlay).
- **0006** Backup & sync: **serverless** — Files/iCloud-Drive export then CloudKit; notebooks never on our server.

*As-built status (2026-06-07):*
- **0001** — Apple Vision (text) and Claude (cloud) are wired and verified; **MyScript deferred**
  (needs paid license + binary SDK). Structured math still unmet (current providers return flat text).
- **0002** — backend proxy is built and used, but the app currently sends a **hardcoded**
  consented/adult session; the real consent surface is still required before any minor cloud use.
- **0003** — honored: deployment target is iPadOS 18.0 and all Anthropic calls go through the proxy.
- **0004** — additive `setObjectState` and `promote` ops added (one-step-undoable); existing
  serialization unchanged. Store is still in-memory (no GRDB/persistence yet).
- **0005** — PKCanvasView host + object overlay run on the Simulator with `.anyInput` drawing; device
  gates (zoom crispness/overlay registration, palm rejection, GPU memory, ink round-trip) still need a
  physical iPad.

## Path to ship — done vs left
**Done & verified here (no device needed):** the 12 libraries (137 tests) + the proxy core (26 tests).
The deterministic brain, the dispatch layer, and the cloud boundary.

**Done in the app (2026-06-08 — Simulator-verified):**
- **Persistence (local):** `JournalStorage`/`FileJournalStorage` — JSONL op log + per-page PKDrawing
  ink blobs under Application Support, replayed on launch via `fold`; the notebook list persists
  (`library.json`, stable ids); background-flush on suspend, `FileProtection`, `fsync`; relaunch
  reopens the last-viewed page. (GRDB impl, op-log compaction, CloudKit sync still left.)
- **Never-lose-ink (local):** PencilKit ink **is** now journaled as per-page PKDrawing blobs and
  survives relaunch.
- **Lasso** two-finger scroll/page-swipe while lassoing; closed-loop marquee; honest ink hit-testing.
- **Make-real polish:** in-place "Designing…" animation at the landing spot; one-pass generation
  (`maxTokens` 8192).
- **Write on a widget:** annotate (Pencil/finger) + handwrite-to-plot via `window.inklab.setInput`.
- **Curve fitting wired:** toolbar Fit → native deterministic `FitGraphView` (`InkLabFit`).

**Left — runtime-coupled (needs an iPad / real services):**
1. **App** — `InkLab/InkLab.xcodeproj` slice runs; flesh out ink↔journal sync, native scroll/zoom + §5.2 paging.
2. **Canvas device gates** (ADR 0005): A native-zoom crispness + overlay registration · B gesture partition feel · C multi-canvas memory · D ink round-trip + recognition · E lasso-drag perf.
3. **WKWebView compute sandbox** — host make-real widgets + the JS engines (math.js/Pyodide/three.js/RDKit/ngspice).
4. **Wire the real Anthropic calls** into the proxy + input/output moderation + negotiated ZDR.
5. **Persistence/sync** — the local file-backed store shipped (2026-06-08); still left: the GRDB
   store, op-log compaction, and `CKSyncEngine` cloud sync for `InkLabDoc`.
6. **Recognition spike** — validate MyScript on real messy student math (see [recognition-spike-plan.md](recognition-spike-plan.md)).
7. **Compliance pre-ship** — the counsel/contract gates (see [compliance-checklist.md](compliance-checklist.md)).

**Current to-do (as of 2026-06-08 — refines the list above):**
- **Consent/compliance surface:** real age screen + App Store §5.1.2(i) third-party-AI permission +
  `NWPathMonitor` reachability feeding a real `SessionContext` (replaces the hardcoded session) —
  required before any cloud use by minors. (Consent/age settings also do **not** yet persist —
  `AppSettings` resets each launch; only the notebook list + journal/ink persist.)
- **Persistence:** local file-backed store shipped (`JournalStorage`/`FileJournalStorage` — JSONL op
  log + per-page PKDrawing ink blobs; replayed on launch; last-viewed page reopens). **Left:** the
  GRDB local op-log + blob store, op-log compaction, then CloudKit/`CKSyncEngine`; re-validate widget
  HTML from another device before loading.
- **MyScript** on-device recognition (paid license + binary SDK) + run the recognition spike on real
  messy student math; structured math (exponents/fractions) needs MyScript or a structured provider.
- **Server hardening:** real input/output moderation (Organizations-Serving-Minors), auth, rate
  limiting, deploy, ZDR + data minimization. The regex widget-HTML validator is defense-in-depth only
  — the `WKWebView` lockdown is the real boundary.
- **Perf:** many live `WKWebView`s (separate processes) — static-raster default, lazy load on
  selection, LRU eviction, keep heavy setup off the ink run-loop.
- **Make-real polish:** a "Designing…" placeholder now animates at the landing spot during generation
  (2026-06-08); generation is one-pass (`maxTokens` 8192). **Left:** true token streaming/progress;
  promote sticker↔interactive↔3D in the UI (the journal `promote` op exists, no UI yet). Generated
  widgets are now annotatable + accept handwritten input via `window.inklab.setInput`.
- **Compute sandbox:** the `WKWebView` now permits `script-src 'unsafe-eval'` so generated
  graphers/calculators can evaluate a user-typed expression (network isolation is still the real
  boundary). **Left:** the bundled JS engines (math.js/three.js/RDKit.js/ngspice-wasm) for the §6
  interpreters are not bundled yet.
- **Remaining §6 interpreters:** the **live lab notebook** (`InkLabFit`, "bring a hand-drawn graph to
  life") shipped (2026-06-08) as the native `FitGraphView`. **Left:** bring-to-life, draw→sticker +
  tray, 2D→3D, executable circuits, reactive knobs (`InkLabReactive`), linked multi-representation
  (`InkLabMultiRep`), proof hints — engines exist for several; UI not wired.
- **Around the canvas:** paging/continuous scroll (§5.2), page-overview, Search UI (`InkLabSearch`
  exists), Study hub, onboarding/empty state.
- **Objects:** rotate; lasso transform of mixed ink+objects; cut/copy/paste across pages & notebooks.
- **Real device:** the proxy URL must point at the Mac's LAN IP / a deployed host (not localhost);
  ADR-0005 device gates need a physical iPad.
- **Accessibility pass;** VoiceOver *into* generated `WKWebView` widgets is unsolved.

## Build & run
- Swift libs: `( cd Packages/<name> && swift test )` — see the [README](../README.md) for the full list.
- Proxy: `( cd Server && npm test )`, `ANTHROPIC_API_KEY=… npm start`.
- App: open `InkLab/InkLab.xcodeproj`, Run on an iPad (`InkLabKit` is linked).

*As built (2026-06-07):* `npm start` auto-loads `Server/.env` (`node --env-file-if-exists=.env`), so
putting `ANTHROPIC_API_KEY` in `Server/.env` is enough. The app reaches the local server via
`NSAllowsLocalNetworking`; on a real device point the proxy URL at the Mac's LAN IP or a deployed
host. Builds and runs on an iPadOS 18 Simulator (Settings → "Finger / mouse drawing" on by default so
the canvas is drawable without a Pencil).
